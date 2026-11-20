//go:build windows

package main

import (
	_ "embed"
	"fmt"
	"log"
	"runtime"
	"syscall"
	"unsafe"
)

// The program shows an icon in the notification area and a small window: whether the site answers, when a file was
// last accepted, and whether the addon's data was found. The window opens when a person starts the program and
// stays closed when the session does (--background); its close button hides it, and the icon's menu shows it again
// or quits.

// A window's messages come to the thread that made it: the main goroutine stays on the main thread.
func init() { runtime.LockOSThread() }

//go:embed icon.png
var iconPNG []byte

const (
	windowClass = "RookieLedgerSyncWindow" // also how another copy finds this one
	appTitle    = "RookieLedger Sync"

	wmDestroy = 0x0002
	wmPaint   = 0x000F
	wmClose   = 0x0010
	wmCommand = 0x0111
	wmLButton = 0x0202 // WM_LBUTTONUP
	wmRButton = 0x0205 // WM_RBUTTONUP
	wmApp     = 0x8000
	msgTray   = wmApp + 1 // the icon was clicked
	msgChange = wmApp + 2 // the view changed
	msgQuit   = wmApp + 3 // a newer copy asks this one to leave

	menuToggle = 1
	menuQuit   = 2

	green = 0x0043A02E // COLORREF: 0x00bbggrr
	red   = 0x002E22CF
	grey  = 0x008C8C8C
	black = 0x00202020
)

type point struct{ x, y int32 }

type rect struct{ left, top, right, bottom int32 }

type wndClassEx struct {
	size, style                        uint32
	wndProc                            uintptr
	clsExtra, wndExtra                 int32
	instance, icon, cursor, background uintptr
	menuName, className                *uint16
	iconSm                             uintptr
}

type msg struct {
	hwnd    uintptr
	message uint32
	wParam  uintptr
	lParam  uintptr
	time    uint32
	pt      point
}

type paintStruct struct {
	hdc                uintptr
	erase              int32
	paint              rect
	restore, incUpdate int32
	reserved           [32]byte
}

type notifyIconData struct {
	size            uint32
	hwnd            uintptr
	id, flags       uint32
	callbackMessage uint32
	icon            uintptr
	tip             [128]uint16
	state, mask     uint32
	info            [256]uint16
	version         uint32
	infoTitle       [64]uint16
	infoFlags       uint32
	guid            [16]byte
	balloonIcon     uintptr
}

type window struct {
	s           *syncer
	hwnd        uintptr
	dpi         int32
	font, bold  uintptr
	small, big  uintptr // the icon at the notification area's size and at the window's
	taskbarBack uint32  // the message Explorer sends when it starts again and has lost every icon
}

var win *window // the one window, for its procedure

func call(dll *syscall.LazyDLL, name string, args ...uintptr) uintptr {
	r, _, _ := dll.NewProc(name).Call(args...)
	return r
}

func utf16(s string) *uint16 {
	p, _ := syscall.UTF16PtrFromString(s)
	return p
}

// findRunning is the window of the copy that already runs in this session, or 0.
func findRunning() uintptr {
	return call(user32, "FindWindowW", uintptr(unsafe.Pointer(utf16(windowClass))), 0)
}

// showRunning opens the running copy's window. It is this process that may come to the front, having just been
// started by the person, so it does the showing itself.
func showRunning() bool {
	h := findRunning()
	if h == 0 {
		return false
	}
	call(user32, "ShowWindowAsync", h, 5) // SW_SHOW
	call(user32, "SetForegroundWindow", h)
	return true
}

// askToQuit asks the running copy to leave by itself, so that it takes its icon away.
func askToQuit() bool {
	h := findRunning()
	return h != 0 && call(user32, "PostMessageW", h, msgQuit, 0, 0) != 0
}

func (w *window) px(n int32) int32 { return n * w.dpi / 96 }

func (w *window) makeFont(points, weight int32) uintptr {
	return call(gdi32, "CreateFontW", uintptr(-(points * w.dpi / 72)), 0, 0, 0, uintptr(weight), 0, 0, 0,
		1 /* DEFAULT_CHARSET */, 0, 0, 5 /* CLEARTYPE_QUALITY */, 0, uintptr(unsafe.Pointer(utf16("Segoe UI"))))
}

// makeIcon builds an icon of the given size from the embedded picture.
func makeIcon(size uintptr) uintptr {
	icon := call(user32, "CreateIconFromResourceEx", uintptr(unsafe.Pointer(&iconPNG[0])), uintptr(len(iconPNG)),
		1, 0x00030000, size, size, 0)
	if icon == 0 {
		icon = call(user32, "LoadIconW", 0, 32512) // IDI_APPLICATION
	}
	return icon
}

func (w *window) create() bool {
	call(user32, "SetProcessDPIAware")
	screen := call(user32, "GetDC", 0)
	w.dpi = int32(call(gdi32, "GetDeviceCaps", screen, 88)) // LOGPIXELSX
	call(user32, "ReleaseDC", 0, screen)
	if w.dpi < 96 {
		w.dpi = 96
	}
	w.font, w.bold = w.makeFont(10, 400), w.makeFont(13, 600)
	w.small = makeIcon(call(user32, "GetSystemMetrics", 49)) // SM_CXSMICON
	w.big = makeIcon(call(user32, "GetSystemMetrics", 11))   // SM_CXICON
	w.taskbarBack = uint32(call(user32, "RegisterWindowMessageW", uintptr(unsafe.Pointer(utf16("TaskbarCreated")))))

	instance := call(kernel32, "GetModuleHandleW", 0)
	class := wndClassEx{wndProc: syscall.NewCallback(windowProc), instance: instance, icon: w.big, iconSm: w.small,
		cursor: call(user32, "LoadCursorW", 0, 32512), background: 5 + 1, // IDC_ARROW, COLOR_WINDOW
		className: utf16(windowClass)}
	class.size = uint32(unsafe.Sizeof(class))
	if call(user32, "RegisterClassExW", uintptr(unsafe.Pointer(&class))) == 0 {
		return false
	}
	const style = 0x00C80000 // WS_CAPTION | WS_SYSMENU: a fixed size, a close button
	frame := rect{0, 0, w.px(430), w.px(190)}
	call(user32, "AdjustWindowRectEx", uintptr(unsafe.Pointer(&frame)), style, 0, 0)
	const useDefault = 0x80000000
	w.hwnd = call(user32, "CreateWindowExW", 0, uintptr(unsafe.Pointer(class.className)),
		uintptr(unsafe.Pointer(utf16(appTitle))), style, useDefault, useDefault,
		uintptr(frame.right-frame.left), uintptr(frame.bottom-frame.top), 0, 0, instance, 0)
	return w.hwnd != 0
}

// tray adds the icon to the notification area, or renews its tooltip.
func (w *window) tray(action uintptr) {
	data := notifyIconData{hwnd: w.hwnd, id: 1, flags: 1 | 2 | 4, callbackMessage: msgTray, icon: w.small} // message, icon, tip
	data.size = uint32(unsafe.Sizeof(data))
	tip := appTitle
	if v := w.s.view(); !v.Checked.IsZero() {
		tip += ": " + text("server") + " " + text(map[bool]string{true: "up", false: "down"}[v.Up])
	}
	shown, _ := syscall.UTF16FromString(tip)
	copy(data.tip[:len(data.tip)-1], shown)
	call(shell32, "Shell_NotifyIconW", action, uintptr(unsafe.Pointer(&data)))
}

func (w *window) visible() bool { return call(user32, "IsWindowVisible", w.hwnd) != 0 }

func (w *window) toggle() {
	if w.visible() {
		call(user32, "ShowWindow", w.hwnd, 0) // SW_HIDE
		return
	}
	call(user32, "ShowWindow", w.hwnd, 5) // SW_SHOW
	call(user32, "SetForegroundWindow", w.hwnd)
}

func (w *window) menu() {
	menu := call(user32, "CreatePopupMenu")
	label := "showwindow"
	if w.visible() {
		label = "hidewindow"
	}
	call(user32, "AppendMenuW", menu, 0, menuToggle, uintptr(unsafe.Pointer(utf16(text(label)))))
	call(user32, "AppendMenuW", menu, 0x800, 0, 0) // MF_SEPARATOR
	call(user32, "AppendMenuW", menu, 0, menuQuit, uintptr(unsafe.Pointer(utf16(text("quit")))))
	var at point
	call(user32, "GetCursorPos", uintptr(unsafe.Pointer(&at)))
	// The menu's owner must be in front, or a click elsewhere does not close the menu.
	call(user32, "SetForegroundWindow", w.hwnd)
	call(user32, "TrackPopupMenu", menu, 0x0020 /* TPM_BOTTOMALIGN */, uintptr(at.x), uintptr(at.y), 0, w.hwnd, 0)
	call(user32, "PostMessageW", w.hwnd, 0, 0, 0)
	call(user32, "DestroyMenu", menu)
}

func (w *window) paint() {
	var ps paintStruct
	dc := call(user32, "BeginPaint", w.hwnd, uintptr(unsafe.Pointer(&ps)))
	defer call(user32, "EndPaint", w.hwnd, uintptr(unsafe.Pointer(&ps)))
	call(gdi32, "SetBkMode", dc, 1) // TRANSPARENT
	write := func(s string, font uintptr, colour uintptr, x, y, width, height int32, flags uintptr) {
		call(gdi32, "SelectObject", dc, font)
		call(gdi32, "SetTextColor", dc, colour)
		box := rect{w.px(x), w.px(y), w.px(x + width), w.px(y + height)}
		text, _ := syscall.UTF16FromString(s)
		call(user32, "DrawTextW", dc, uintptr(unsafe.Pointer(&text[0])), uintptr(len(text)-1),
			uintptr(unsafe.Pointer(&box)), flags|0x0800) // DT_NOPREFIX
	}
	const (
		margin, column, wide, line = 22, 170, 386, 22
		single                     = 0x0020 | 0x8000 // DT_SINGLELINE | DT_END_ELLIPSIS
	)
	v := w.s.view()
	write(appTitle, w.bold, black, margin, 16, 260, 28, single)
	write(version, w.font, grey, margin+260, 21, wide-260, line, single|0x0002) // DT_RIGHT

	state, colour := text("checking"), uintptr(grey)
	if !v.Checked.IsZero() {
		state, colour = text("down"), red
		if v.Up {
			state, colour = text("up"), green
		}
		state += " (" + v.Checked.Format("15:04") + ")"
	}
	write(text("server"), w.font, grey, margin, 62, column-margin, line, single)
	brush := call(gdi32, "CreateSolidBrush", colour)
	call(gdi32, "SelectObject", dc, brush)
	call(gdi32, "SelectObject", dc, call(gdi32, "GetStockObject", 8)) // NULL_PEN
	call(gdi32, "Ellipse", dc, uintptr(w.px(column)), uintptr(w.px(67)), uintptr(w.px(column+13)), uintptr(w.px(80)))
	call(gdi32, "SelectObject", dc, call(gdi32, "GetStockObject", 0)) // WHITE_BRUSH, so that ours can go
	call(gdi32, "DeleteObject", brush)
	write(state, w.font, black, column+20, 62, wide+margin-column-20, line, single)

	last := text("never")
	if !v.LastSync.IsZero() {
		last = v.LastSync.Local().Format(text("date"))
	}
	write(text("lastsync"), w.font, grey, margin, 90, column-margin, line, single)
	write(last, w.font, black, column, 90, wide+margin-column, line, single)

	data, foot := "…", text("installed")
	switch {
	case v.Files == 0:
		data, foot = text("nodata"), text("hint")
	case v.Files > 0:
		data = fmt.Sprintf(text("accounts"), v.Files)
	}
	write(text("gamedata"), w.font, grey, margin, 118, column-margin, line, single)
	write(data, w.font, black, column, 118, wide+margin-column, line, single)
	write(foot, w.font, grey, margin, 150, wide, 2*line, 0x0010) // DT_WORDBREAK
}

func windowProc(hwnd uintptr, message uint32, wParam, lParam uintptr) uintptr {
	w := win
	if w == nil || hwnd != w.hwnd {
		return call(user32, "DefWindowProcW", hwnd, uintptr(message), wParam, lParam)
	}
	switch message {
	case wmPaint:
		w.paint()
	case wmClose:
		call(user32, "ShowWindow", hwnd, 0) // the close button hides; the icon's menu quits
	case msgTray:
		switch lParam {
		case wmLButton:
			w.toggle()
		case wmRButton:
			w.menu()
		}
	case wmCommand:
		switch wParam & 0xffff {
		case menuToggle:
			w.toggle()
		case menuQuit:
			call(user32, "DestroyWindow", hwnd)
		}
	case msgChange:
		w.tray(1) // NIM_MODIFY
		call(user32, "InvalidateRect", hwnd, 0, 1)
	case msgQuit:
		call(user32, "DestroyWindow", hwnd)
	case wmDestroy:
		w.tray(2) // NIM_DELETE
		call(user32, "PostQuitMessage", 0)
	default:
		if message == w.taskbarBack && message != 0 {
			w.tray(0) // NIM_ADD
		}
		return call(user32, "DefWindowProcW", hwnd, uintptr(message), wParam, lParam)
	}
	return 0
}

// serve runs the watching loop beside the window, until the icon's menu quits the program.
func serve(s *syncer, show bool, watch func()) {
	w := &window{s: s}
	win = w
	if !w.create() {
		log.Printf("no window: running without one")
		win = nil
		watch()
		return
	}
	s.probeEvery = probeEvery
	s.changed = func() { call(user32, "PostMessageW", w.hwnd, msgChange, 0, 0) }
	w.tray(0) // NIM_ADD
	if show {
		w.toggle()
	}
	go watch()
	var m msg
	for int32(call(user32, "GetMessageW", uintptr(unsafe.Pointer(&m)), 0, 0, 0)) > 0 {
		call(user32, "TranslateMessage", uintptr(unsafe.Pointer(&m)))
		call(user32, "DispatchMessageW", uintptr(unsafe.Pointer(&m)))
	}
}

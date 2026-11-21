//go:build windows

package main

import (
	"embed"
	"fmt"
	"log"
	"runtime"
	"syscall"
	"unsafe"
)

// The program shows an icon in the notification area and a small window: whether the site answers, when a file was
// last accepted, and whether the addon's data was found. The window opens when a person starts the program and
// stays closed when the session does (--background); its close button hides it, and the icon's menu shows it again
// or quits. That menu also holds the two settings: whether the program starts with the session, and whether the
// window says more (the debug setting: below its three lines, why the site or the game's data is not found).
//
// The window is drawn by hand, in the manner of Windows 11: the system's font, a rounded card on the settings
// pages' grey, light or dark as the person chose for apps, and at the scale of the screen it is on. Shapes go
// through GDI+, which smooths their edges; text goes through GDI, which draws it as the rest of Windows does.

// A window's messages come to the thread that made it: the main goroutine stays on the main thread.
func init() { runtime.LockOSThread() }

// The icon, drawn at each size Windows asks for at its usual scales: one picture stretched to fit comes out soft.
//
//go:embed icons/*.png
var icons embed.FS

var iconSizes = []int32{16, 20, 24, 28, 32, 40, 48, 56, 64, 256}

var (
	dwmapi  = syscall.NewLazyDLL("dwmapi.dll")
	gdiplus = syscall.NewLazyDLL("gdiplus.dll")
	shlwapi = syscall.NewLazyDLL("shlwapi.dll")
	ntdll   = syscall.NewLazyDLL("ntdll.dll")
)

const (
	windowClass = "RookieLedgerSyncWindow" // also how another copy finds this one
	appTitle    = "RookieLedger Sync"

	wmDestroy = 0x0002
	wmPaint   = 0x000F
	wmClose   = 0x0010
	wmErase   = 0x0014 // WM_ERASEBKGND
	wmSetting = 0x001A // WM_SETTINGCHANGE: among others, light and dark were switched
	wmCommand = 0x0111
	wmLButton = 0x0202 // WM_LBUTTONUP
	wmRButton = 0x0205 // WM_RBUTTONUP
	wmDPI     = 0x02E0 // WM_DPICHANGED: the window is now on a screen of another scale
	wmApp     = 0x8000
	msgTray   = wmApp + 1 // the icon was clicked
	msgChange = wmApp + 2 // the view changed
	msgQuit   = wmApp + 3 // a newer copy asks this one to leave

	menuToggle    = 1
	menuQuit      = 2
	menuAutostart = 3
	menuDebug     = 4

	windowStyle = 0x00C80000 // WS_CAPTION | WS_SYSMENU: a fixed size, a close button

	// The window's inside, in the pixels of a screen at 100 %.
	clientWide, clientHigh = 420, 268
	margin                 = 24
	cardTop, rowHigh       = 86, 40
	column                 = 184 // where the values start
	debugHigh              = 196 // what the debug setting adds below: a rule, then the details
)

// colours of the window, each as 0xRRGGBB.
type palette struct {
	back, card, edge, rule, ink, dim, up, down, idle uint32
}

var (
	lightColours = palette{back: 0xF3F3F3, card: 0xFFFFFF, edge: 0xE5E5E5, rule: 0xEDEDED, ink: 0x1B1B1B, dim: 0x5F5F5F,
		up: 0x0F7B0F, down: 0xC42B1C, idle: 0x8A8A8A}
	darkColours = palette{back: 0x202020, card: 0x2B2B2B, edge: 0x3A3A3A, rule: 0x383838, ink: 0xFFFFFF, dim: 0xC5C5C5,
		up: 0x6CCB5F, down: 0xFF99A4, idle: 0x9A9A9A}
)

// colorref is a colour as GDI takes it (0x00bbggrr), argb as GDI+ does (opaque).
func colorref(c uint32) uintptr { return uintptr(c>>16&0xff | c&0xff00 | c&0xff<<16) }
func argb(c uint32) uintptr     { return uintptr(0xFF000000 | c) }

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
	face        string  // the system's font: Segoe UI Variable on Windows 11, Segoe UI before
	font, bold  uintptr // at the window's scale
	small, big  uintptr // the icon at the sizes of the window's title and of the task switcher
	trayIcon    uintptr // and at the notification area's
	picture     uintptr // the large icon as a GDI+ image, for the window's heading
	colours     palette
	taskbarBack uint32 // the message Explorer sends when it starts again and has lost every icon
	store       bool   // run from the Store package: Windows holds the switch of the start with the session
}

var win *window // the one window, for its procedure

func call(dll *syscall.LazyDLL, name string, args ...uintptr) uintptr {
	r, _, _ := dll.NewProc(name).Call(args...)
	return r
}

// has tells whether this Windows has the function: the newer ones are asked for by name, never assumed.
func has(dll *syscall.LazyDLL, name string) bool { return dll.NewProc(name).Find() == nil }

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

// windowsBuild is the build number of this Windows (22000 is the first Windows 11), 0 when it does not say.
func windowsBuild() uint32 {
	var info [284]byte // OSVERSIONINFOEXW: its size first, the build number fourth
	*(*uint32)(unsafe.Pointer(&info[0])) = uint32(len(info))
	if call(ntdll, "RtlGetVersion", uintptr(unsafe.Pointer(&info[0]))) != 0 {
		return 0
	}
	return *(*uint32)(unsafe.Pointer(&info[12]))
}

// darkApps tells whether the person chose the dark mode for apps.
func darkApps() bool {
	var key syscall.Handle
	path := utf16(`Software\Microsoft\Windows\CurrentVersion\Themes\Personalize`)
	if syscall.RegOpenKeyEx(syscall.HKEY_CURRENT_USER, path, 0, syscall.KEY_READ, &key) != nil {
		return false
	}
	defer syscall.RegCloseKey(key)
	var kind, light uint32
	size := uint32(4)
	if syscall.RegQueryValueEx(key, utf16("AppsUseLightTheme"), nil, &kind, (*byte)(unsafe.Pointer(&light)), &size) != nil ||
		kind != syscall.REG_DWORD {
		return false
	}
	return light == 0
}

func (w *window) px(n int32) int32 { return (n*w.dpi + 48) / 96 }

// high is the height of the window's inside, in the pixels of a screen at 100 %.
func (w *window) high() int32 {
	if w.s.st.debug() {
		return clientHigh + debugHigh
	}
	return clientHigh
}

func (w *window) makeFont(points, weight int32) uintptr {
	return call(gdi32, "CreateFontW", uintptr(-((points*w.dpi + 36) / 72)), 0, 0, 0, uintptr(weight), 0, 0, 0,
		1 /* DEFAULT_CHARSET */, 0, 0, 5 /* CLEARTYPE_QUALITY */, 0, uintptr(unsafe.Pointer(utf16(w.face))))
}

func iconFile(size int32) []byte {
	drawn := iconSizes[len(iconSizes)-1]
	for _, s := range iconSizes {
		if s >= size {
			drawn = s
			break
		}
	}
	png, _ := icons.ReadFile(fmt.Sprintf("icons/%d.png", drawn))
	return png
}

// makeIcon builds an icon of the given size from the embedded picture of that size, or the next one up.
func makeIcon(size int32) uintptr {
	var icon uintptr
	if png := iconFile(size); len(png) > 0 {
		icon = call(user32, "CreateIconFromResourceEx", uintptr(unsafe.Pointer(&png[0])), uintptr(len(png)),
			1, 0x00030000, uintptr(size), uintptr(size), 0)
	}
	if icon == 0 {
		icon = call(user32, "LoadIconW", 0, 32512) // IDI_APPLICATION
	}
	return icon
}

// theme takes the person's choice of light or dark, for the window's inside and for its title bar.
func (w *window) theme() {
	dark := darkApps()
	w.colours = lightColours
	if dark {
		w.colours = darkColours
	}
	if has(dwmapi, "DwmSetWindowAttribute") {
		on := int32(0)
		if dark {
			on = 1
		}
		call(dwmapi, "DwmSetWindowAttribute", w.hwnd, 20, uintptr(unsafe.Pointer(&on)), 4) // DWMWA_USE_IMMERSIVE_DARK_MODE
	}
	call(user32, "InvalidateRect", w.hwnd, 0, 0)
}

// scale takes the scale of the screen the window is on: fonts and icons for it, and the window's size.
func (w *window) scale(dpi int32, place *rect) {
	if dpi < 96 {
		dpi = 96
	}
	for _, old := range []uintptr{w.font, w.bold} {
		if old != 0 {
			call(gdi32, "DeleteObject", old)
		}
	}
	w.dpi = dpi
	w.font, w.bold = w.makeFont(10, 400), w.makeFont(15, 600)
	small, big := makeIcon(w.px(16)), makeIcon(w.px(32))
	call(user32, "SendMessageW", w.hwnd, 0x0080, 0, small) // WM_SETICON, ICON_SMALL
	call(user32, "SendMessageW", w.hwnd, 0x0080, 1, big)   // ICON_BIG
	for _, old := range []uintptr{w.small, w.big} {
		if old != 0 {
			call(user32, "DestroyIcon", old)
		}
	}
	w.small, w.big = small, big
	const noMove, noZOrder, noActivate = 0x0002, 0x0004, 0x0010
	if place != nil { // where Windows suggests, on the new screen
		call(user32, "SetWindowPos", w.hwnd, 0, uintptr(place.left), uintptr(place.top),
			uintptr(place.right-place.left), uintptr(place.bottom-place.top), noZOrder|noActivate)
	} else {
		frame := rect{0, 0, w.px(clientWide), w.px(w.high())}
		if !has(user32, "AdjustWindowRectExForDpi") ||
			call(user32, "AdjustWindowRectExForDpi", uintptr(unsafe.Pointer(&frame)), windowStyle, 0, 0, uintptr(dpi)) == 0 {
			call(user32, "AdjustWindowRectEx", uintptr(unsafe.Pointer(&frame)), windowStyle, 0, 0)
		}
		call(user32, "SetWindowPos", w.hwnd, 0, 0, 0, uintptr(frame.right-frame.left), uintptr(frame.bottom-frame.top),
			noMove|noZOrder|noActivate)
	}
	call(user32, "InvalidateRect", w.hwnd, 0, 0)
}

func (w *window) create() bool {
	// Each screen at its own scale (Windows 10 1703 on); before that, the main screen's scale for all.
	if !has(user32, "SetProcessDpiAwarenessContext") ||
		call(user32, "SetProcessDpiAwarenessContext", ^uintptr(3)) == 0 { // DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2
		call(user32, "SetProcessDPIAware")
	}
	w.face = "Segoe UI"
	if windowsBuild() >= 22000 {
		w.face = "Segoe UI Variable Text"
	}
	// GDI+ for the shapes and the heading's picture. Without it the window keeps its text and loses those.
	startup := struct {
		version          uint32
		callback         uintptr
		noThread, noCode int32
	}{version: 1}
	var token uintptr
	if call(gdiplus, "GdiplusStartup", uintptr(unsafe.Pointer(&token)), uintptr(unsafe.Pointer(&startup)), 0) == 0 {
		if png := iconFile(256); len(png) > 0 && has(shlwapi, "SHCreateMemStream") {
			// The stream keeps its own copy of the bytes, and lives as long as the picture: as long as the program.
			if stream := call(shlwapi, "SHCreateMemStream", uintptr(unsafe.Pointer(&png[0])), uintptr(len(png))); stream != 0 {
				call(gdiplus, "GdipCreateBitmapFromStream", stream, uintptr(unsafe.Pointer(&w.picture)))
			}
		}
	}
	w.taskbarBack = uint32(call(user32, "RegisterWindowMessageW", uintptr(unsafe.Pointer(utf16("TaskbarCreated")))))

	instance := call(kernel32, "GetModuleHandleW", 0)
	class := wndClassEx{wndProc: syscall.NewCallback(windowProc), instance: instance,
		cursor: call(user32, "LoadCursorW", 0, 32512), className: utf16(windowClass)} // IDC_ARROW
	class.size = uint32(unsafe.Sizeof(class))
	if call(user32, "RegisterClassExW", uintptr(unsafe.Pointer(&class))) == 0 {
		return false
	}
	const useDefault = 0x80000000
	w.hwnd = call(user32, "CreateWindowExW", 0, uintptr(unsafe.Pointer(class.className)),
		uintptr(unsafe.Pointer(utf16(appTitle))), windowStyle, useDefault, useDefault, clientWide, clientHigh,
		0, 0, instance, 0)
	if w.hwnd == 0 {
		return false
	}
	var dpi int32
	if has(user32, "GetDpiForWindow") {
		dpi = int32(call(user32, "GetDpiForWindow", w.hwnd))
	} else {
		screen := call(user32, "GetDC", 0)
		dpi = int32(call(gdi32, "GetDeviceCaps", screen, 88)) // LOGPIXELSX
		call(user32, "ReleaseDC", 0, screen)
	}
	w.theme()
	w.scale(dpi, nil)
	// The notification area is on the main screen: its icon is drawn at that screen's size.
	w.trayIcon = makeIcon(int32(call(user32, "GetSystemMetrics", 49))) // SM_CXSMICON
	return true
}

// tray adds the icon to the notification area, or renews its tooltip.
func (w *window) tray(action uintptr) {
	data := notifyIconData{hwnd: w.hwnd, id: 1, flags: 1 | 2 | 4, callbackMessage: msgTray, icon: w.trayIcon} // message, icon, tip
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
	checked := func(on bool) uintptr {
		if on {
			return 0x8 // MF_CHECKED
		}
		return 0
	}
	call(user32, "AppendMenuW", menu, 0, menuToggle, uintptr(unsafe.Pointer(utf16(text(label)))))
	call(user32, "AppendMenuW", menu, 0x800, 0, 0) // MF_SEPARATOR
	if w.store {
		call(user32, "AppendMenuW", menu, 0, menuAutostart, uintptr(unsafe.Pointer(utf16(text("startupsettings")))))
	} else {
		call(user32, "AppendMenuW", menu, checked(w.s.st.autostart()), menuAutostart, uintptr(unsafe.Pointer(utf16(text("autostart")))))
	}
	call(user32, "AppendMenuW", menu, checked(w.s.st.debug()), menuDebug, uintptr(unsafe.Pointer(utf16(text("debug")))))
	call(user32, "AppendMenuW", menu, 0x800, 0, 0)
	call(user32, "AppendMenuW", menu, 0, menuQuit, uintptr(unsafe.Pointer(utf16(text("quit")))))
	var at point
	call(user32, "GetCursorPos", uintptr(unsafe.Pointer(&at)))
	// The menu's owner must be in front, or a click elsewhere does not close the menu.
	call(user32, "SetForegroundWindow", w.hwnd)
	call(user32, "TrackPopupMenu", menu, 0x0020 /* TPM_BOTTOMALIGN */, uintptr(at.x), uintptr(at.y), 0, w.hwnd, 0)
	call(user32, "PostMessageW", w.hwnd, 0, 0, 0)
	call(user32, "DestroyMenu", menu)
}

// shapes draws what has curves, with smooth edges: the card, the heading's picture and the status dot. Sizes are
// in the screen's own pixels. GDI+ takes whole numbers through these calls, which is all that is needed here.
func (w *window) shapes(dc uintptr, dot uint32) {
	var g uintptr
	if !has(gdiplus, "GdipCreateFromHDC") || call(gdiplus, "GdipCreateFromHDC", dc, uintptr(unsafe.Pointer(&g))) != 0 {
		return
	}
	defer call(gdiplus, "GdipDeleteGraphics", g)
	call(gdiplus, "GdipSetSmoothingMode", g, 4)     // anti-aliased
	call(gdiplus, "GdipSetInterpolationMode", g, 7) // high-quality bicubic, for the picture
	call(gdiplus, "GdipSetPixelOffsetMode", g, 2)   // a shape's edge falls between pixels, not through them
	fill := func(colour uint32, draw func(brush uintptr)) {
		var brush uintptr
		if call(gdiplus, "GdipCreateSolidFill", argb(colour), uintptr(unsafe.Pointer(&brush))) == 0 {
			draw(brush)
			call(gdiplus, "GdipDeleteBrush", brush)
		}
	}
	// A rectangle with round corners is two rectangles laid across each other and a disc in each corner.
	round := func(colour uint32, x, y, wide, high, r int32) {
		fill(colour, func(brush uintptr) {
			box := func(x, y, wide, high int32) {
				call(gdiplus, "GdipFillRectangleI", g, brush, uintptr(x), uintptr(y), uintptr(wide), uintptr(high))
			}
			box(x+r, y, wide-2*r, high)
			box(x, y+r, wide, high-2*r)
			for _, c := range []point{{x, y}, {x + wide - 2*r, y}, {x, y + high - 2*r}, {x + wide - 2*r, y + high - 2*r}} {
				call(gdiplus, "GdipFillEllipseI", g, brush, uintptr(c.x), uintptr(c.y), uintptr(2*r), uintptr(2*r))
			}
		})
	}
	x, y, wide, high, r := w.px(margin), w.px(cardTop), w.px(clientWide-2*margin), w.px(3*rowHigh), w.px(8)
	round(w.colours.edge, x, y, wide, high, r)
	round(w.colours.card, x+1, y+1, wide-2, high-2, r-1)
	if w.picture != 0 {
		call(gdiplus, "GdipDrawImageRectI", g, w.picture, uintptr(w.px(margin)), uintptr(w.px(22)), uintptr(w.px(44)), uintptr(w.px(44)))
	}
	fill(dot, func(brush uintptr) {
		size := w.px(10)
		call(gdiplus, "GdipFillEllipseI", g, brush, uintptr(w.px(column)), uintptr(w.px(cardTop)+(w.px(rowHigh)-size)/2),
			uintptr(size), uintptr(size))
	})
}

func (w *window) paint() {
	var ps paintStruct
	screen := call(user32, "BeginPaint", w.hwnd, uintptr(unsafe.Pointer(&ps)))
	defer call(user32, "EndPaint", w.hwnd, uintptr(unsafe.Pointer(&ps)))
	// Drawn aside and shown at once, so that nothing flickers.
	var all rect
	call(user32, "GetClientRect", w.hwnd, uintptr(unsafe.Pointer(&all)))
	dc := call(gdi32, "CreateCompatibleDC", screen)
	sheet := call(gdi32, "CreateCompatibleBitmap", screen, uintptr(all.right), uintptr(all.bottom))
	before := call(gdi32, "SelectObject", dc, sheet)
	defer func() {
		call(gdi32, "BitBlt", screen, 0, 0, uintptr(all.right), uintptr(all.bottom), dc, 0, 0, 0x00CC0020) // SRCCOPY
		call(gdi32, "SelectObject", dc, before)
		call(gdi32, "DeleteObject", sheet)
		call(gdi32, "DeleteDC", dc)
	}()
	block := func(colour uint32, box rect) {
		brush := call(gdi32, "CreateSolidBrush", colorref(colour))
		call(user32, "FillRect", dc, uintptr(unsafe.Pointer(&box)), brush)
		call(gdi32, "DeleteObject", brush)
	}
	block(w.colours.back, all)

	v := w.s.view()
	state, dot := text("checking"), w.colours.idle
	if !v.Checked.IsZero() {
		state, dot = text("down"), w.colours.down
		if v.Up {
			state, dot = text("up"), w.colours.up
		}
		state += " (" + v.Checked.Format("15:04") + ")"
	}
	w.shapes(dc, dot)

	call(gdi32, "SetBkMode", dc, 1) // TRANSPARENT
	const (
		single = 0x0020 | 0x8000 // DT_SINGLELINE | DT_END_ELLIPSIS
		middle = single | 0x0004 // DT_VCENTER
	)
	write := func(s string, font uintptr, colour uint32, x, y, wide, high int32, flags uintptr) {
		call(gdi32, "SelectObject", dc, font)
		call(gdi32, "SetTextColor", dc, colorref(colour))
		box := rect{w.px(x), w.px(y), w.px(x + wide), w.px(y + high)}
		text, _ := syscall.UTF16FromString(s)
		call(user32, "DrawTextW", dc, uintptr(unsafe.Pointer(&text[0])), uintptr(len(text)-1),
			uintptr(unsafe.Pointer(&box)), flags|0x0800) // DT_NOPREFIX
	}
	const heading = margin + 44 + 14 // beside the picture
	write(appTitle, w.bold, w.colours.ink, heading, 20, clientWide-margin-heading, 28, middle)
	write(version, w.font, w.colours.dim, heading, 48, clientWide-margin-heading, 20, middle)

	last := text("never")
	if !v.LastSync.IsZero() {
		last = v.LastSync.Local().Format(text("date"))
	}
	data, foot := "…", text("installed")
	if !w.store && !w.s.st.autostart() {
		foot = text("manual")
	}
	switch {
	case v.Files == 0:
		data, foot = text("nodata"), text("hint")
	case v.Files > 0:
		data = fmt.Sprintf(text("accounts"), v.Files)
	}
	const inside = margin + 16 // the card's own margin
	for i, row := range [][2]string{{text("server"), state}, {text("lastsync"), last}, {text("gamedata"), data}} {
		top := int32(cardTop + i*rowHigh)
		if i > 0 {
			block(w.colours.rule, rect{w.px(inside), w.px(top), w.px(clientWide - inside), w.px(top) + 1})
		}
		value := int32(column)
		if i == 0 {
			value += 18 // after the dot
		}
		write(row[0], w.font, w.colours.dim, inside, top, column-inside-8, rowHigh, middle)
		write(row[1], w.font, w.colours.ink, value, top, clientWide-inside-value, rowHigh, middle)
	}
	write(foot, w.font, w.colours.dim, margin, cardTop+3*rowHigh+14, clientWide-2*margin, 44, 0x0010) // DT_WORDBREAK
	if w.s.st.debug() {
		block(w.colours.rule, rect{w.px(margin), w.px(clientHigh), w.px(clientWide - margin), w.px(clientHigh) + 1})
		// DT_WORDBREAK | DT_EDITCONTROL: a folder's path has no space to break at, and is broken where the line ends.
		write(w.s.details(), w.font, w.colours.dim, margin, clientHigh+12, clientWide-2*margin, debugHigh-24, 0x0010|0x2000)
	}
}

// setAutostart is the menu's first setting. For the Store package, Windows holds the switch: its page is opened.
func (w *window) setAutostart() {
	if w.store {
		openStartupSettings()
		return
	}
	st := w.s.st
	var on bool
	st.change(func() { st.NoAutostart = !st.NoAutostart; on = !st.NoAutostart })
	w.s.save()
	if err := setAutostart(on); err != nil {
		notify(text("noautostart") + err.Error())
	}
	call(user32, "InvalidateRect", w.hwnd, 0, 0)
}

// setDebug is the menu's second setting: the window grows by the details, or gives them up.
func (w *window) setDebug() {
	st := w.s.st
	st.change(func() { st.Debug = !st.Debug })
	w.s.save()
	w.scale(w.dpi, nil)
}

func windowProc(hwnd uintptr, message uint32, wParam, lParam uintptr) uintptr {
	w := win
	if w == nil || hwnd != w.hwnd {
		return call(user32, "DefWindowProcW", hwnd, uintptr(message), wParam, lParam)
	}
	switch message {
	case wmPaint:
		w.paint()
	case wmErase:
		return 1 // paint covers everything
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
		case menuAutostart:
			w.setAutostart()
		case menuDebug:
			w.setDebug()
		}
	case msgChange:
		w.tray(1) // NIM_MODIFY
		call(user32, "InvalidateRect", hwnd, 0, 0)
	case wmSetting:
		w.theme()
	case wmDPI:
		var place rect // copied from where Windows keeps the place it suggests
		call(kernel32, "RtlMoveMemory", uintptr(unsafe.Pointer(&place)), lParam, unsafe.Sizeof(place))
		w.scale(int32(wParam>>16&0xffff), &place)
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
	w := &window{s: s, dpi: 96, colours: lightColours, store: packaged()}
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

//go:build windows

package main

import (
	"embed"
	"fmt"
	"log"
	"math"
	"runtime"
	"syscall"
	"unsafe"
)

// The program shows an icon in the notification area and a small window: whether the site answers, when a file was
// last accepted, whether the addon's data was found, how often the saved files are looked at (a drop-down list) and
// whether the program starts with the session (a switch). A button in it asks for the game's folder, with Windows'
// own folder dialog, for when the program does not find it by itself; another opens the advanced settings below:
// the upload address, the debug setting (the window then says why the site or the game's data is not found) and
// where the log is. The window opens when a person starts the program and stays closed when the session does
// (--background). Its close button hides it, and the icon's menu shows it again or quits.
//
// The window is drawn by hand, in the manner of Windows 11: the system's font, rounded cards on the settings
// pages' grey, light or dark as the person chose for apps, and at the scale of the screen it is on. Shapes go
// through GDI+, which smooths their edges; text goes through GDI, which draws it as the rest of Windows does. The
// address field alone is Windows' own: typing, the caret, selecting and pasting are not redone by hand.

// A window's messages come to the thread that made it: the main goroutine stays on the main thread.
func init() { runtime.LockOSThread() }

// The icon, drawn at each size Windows asks for at its usual scales: one picture stretched to fit comes out soft.
//
//go:embed icons/*.png
var icons embed.FS

var iconSizes = []int32{16, 20, 24, 28, 32, 40, 48, 56, 64, 256}

var (
	ole32   = syscall.NewLazyDLL("ole32.dll")
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
	wmCursor  = 0x0020 // WM_SETCURSOR
	wmKeyDown = 0x0100
	wmCommand = 0x0111
	wmEditBg  = 0x0133 // WM_CTLCOLOREDIT: the address field asks for its colours
	wmMove    = 0x0200 // WM_MOUSEMOVE
	wmLDown   = 0x0201 // WM_LBUTTONDOWN
	wmLButton = 0x0202 // WM_LBUTTONUP
	wmLeave   = 0x02A3 // WM_MOUSELEAVE
	wmRButton = 0x0205 // WM_RBUTTONUP
	wmDPI     = 0x02E0 // WM_DPICHANGED: the window is now on a screen of another scale
	wmApp     = 0x8000
	msgTray   = wmApp + 1 // the icon was clicked
	msgChange = wmApp + 2 // the view changed
	msgQuit   = wmApp + 3 // a newer copy asks this one to leave

	menuToggle = 1
	menuQuit   = 2
	menuPoll   = 100 // the first choice of the drop-down list
	fieldID    = 10  // the address field, as its messages name it

	// WS_CLIPCHILDREN | WS_CAPTION | WS_SYSMENU: a fixed size, a close button, and the window's painting goes around
	// the address field.
	windowStyle = 0x02C80000

	// The window's inside, in the pixels of a screen at 100 %.
	clientWide             = 420
	margin                 = 24
	cardTop, rowHigh, rows = 86, 40, 5
	column                 = 184         // where the values start
	inside                 = margin + 16 // the card's own margin
	// The fourth row's value is a drop-down list: how often the saved files are looked at. The fifth's is a switch
	// (On or Off written before it), or, for the Store package, a button that opens Windows' own.
	listTop, listHigh, listWide = cardTop + 3*rowHigh + 5, rowHigh - 10, clientWide - inside - column
	startTop, startWide         = cardTop + 4*rowHigh, 172
	switchWide, switchHigh      = 40, 20
	stateWide                   = 80
	switchLeft                  = clientWide - inside - switchWide
	stateLeft                   = switchLeft - 10 - stateWide
	// Below the card: the button that asks for the game's folder, the one that opens the advanced settings, and a
	// line of text.
	buttonTop, buttonHigh, buttonWide = cardTop + rows*rowHigh + 12, 32, 200
	moreLeft, moreWide                = margin + buttonWide + 8, clientWide - 2*margin - buttonWide - 8
	footTop, footHigh                 = buttonTop + buttonHigh + 10, 40
	clientHigh                        = footTop + footHigh + 8 // with the advanced settings closed
	// The advanced settings: a second card of three rows (the address, the debug setting, the log), the address's
	// with a note below its field in the room its longest text takes (the window's noteHigh), then, while the debug
	// setting is on, the details, in as much room as they need up to maxDetails.
	moreTop, noteTop    = clientHigh, clientHigh + rowHigh - 2
	fieldLeft, saveWide = inside + 64, 88
	saveLeft            = clientWide - inside - saveWide
	fieldWide           = saveLeft - 8 - fieldLeft
	maxDetails          = 196
	// What the pointer is on.
	onFolder, onList, onStart, onMore, onField, onSave, onDebug = 1, 2, 3, 4, 5, 6, 7
)

// colours of the window, each as 0xRRGGBB.
type palette struct {
	back, card, edge, rule, ink, dim, up, down, idle uint32
	accent, knob                                     uint32 // a switch that is on, and its knob: Windows' own blue
}

var (
	lightColours = palette{back: 0xF3F3F3, card: 0xFFFFFF, edge: 0xE5E5E5, rule: 0xEDEDED, ink: 0x1B1B1B, dim: 0x5F5F5F,
		up: 0x0F7B0F, down: 0xC42B1C, idle: 0x8A8A8A, accent: 0x005FB8, knob: 0xFFFFFF}
	darkColours = palette{back: 0x202020, card: 0x2B2B2B, edge: 0x3A3A3A, rule: 0x383838, ink: 0xFFFFFF, dim: 0xC5C5C5,
		up: 0x6CCB5F, down: 0xFF99A4, idle: 0x9A9A9A, accent: 0x60CDFF, knob: 0x000000}
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
	taskbarBack uint32  // the message Explorer sends when it starts again and has lost every icon
	store       bool    // run from the Store package: Windows holds the switch of the start with the session
	hover       int     // what the pointer is on: onFolder, onList and the others, or 0
	pressed     int     // what the mouse button went down on, until it comes up
	choosing    bool    // the folder dialog is open
	advanced    bool    // the advanced settings show
	detailsHigh int32   // the room the details take, in the pixels of a screen at 100 %; 0 when they do not show
	noteHigh    int32   // the room of the note below the address field: its longest text and a gap, likewise
	field       uintptr // the address field, Windows' own
	fieldBrush  uintptr // its background: the card's colour
	lineHigh    int32   // a line of the window's font, in the screen's pixels: the field's height
	address     string  // the address saved, "" for the RookieLedger site
	fieldError  string  // why what was typed in the field was not taken, until it is typed again
}

var win *window // the one window, for its procedure

// call runs a function of Windows. What an argument points to is written as uintptr(unsafe.Pointer(&x)) in the
// call itself: the directive below keeps x where it is and alive until Windows has answered, which a number alone
// does not (the goroutine's stack moves when it grows or shrinks).
//
//go:uintptrescapes
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

// noteTexts are the keys of what the note below the address field can say (see note): the note takes the room of the
// longest, so that the rows below it stay in place whatever it says.
var noteTexts = []string{"addresshelp", "addresschecking", "addressok", "addresswrong", "addressdown", "needhttps"}

// Below the note, the advanced settings' second and third rows, then the details; in the pixels of a screen at 100 %.
func (w *window) debugTop() int32   { return noteTop + w.noteHigh }
func (w *window) logTop() int32     { return w.debugTop() + rowHigh }
func (w *window) moreHigh() int32   { return w.logTop() + rowHigh - moreTop }
func (w *window) detailsTop() int32 { return moreTop + w.moreHigh() + 12 }

// high is the height of the window's inside, in the pixels of a screen at 100 %.
func (w *window) high() int32 {
	switch {
	case !w.advanced:
		return clientHigh
	case w.detailsHigh > 0:
		return w.detailsTop() + w.detailsHigh + 12
	}
	return moreTop + w.moreHigh() + 16
}

// measure is the room a text takes in a box as wide as given, in the pixels of a screen at 100 %.
func (w *window) measure(s string, wide int32) int32 {
	if s == "" {
		return 0
	}
	dc := call(user32, "GetDC", w.hwnd)
	defer call(user32, "ReleaseDC", w.hwnd, dc)
	before := call(gdi32, "SelectObject", dc, w.font)
	defer call(gdi32, "SelectObject", dc, before)
	box := rect{0, 0, w.px(wide), 0}
	text, _ := syscall.UTF16FromString(s)
	call(user32, "DrawTextW", dc, uintptr(unsafe.Pointer(&text[0])), uintptr(len(text)-1), uintptr(unsafe.Pointer(&box)),
		0x0400|0x0010|0x2000|0x0800) // DT_CALCRECT | DT_WORDBREAK | DT_EDITCONTROL | DT_NOPREFIX, as paint writes it
	return (box.bottom*96 + w.dpi - 1) / w.dpi
}

// fit gives the window the height of what it shows: the details grow and shrink with what they say. always: the
// advanced settings or the details were just opened or closed.
func (w *window) fit(always bool) {
	high := int32(0)
	if w.advanced && w.s.st.debug() {
		high = min(w.measure(w.s.details(), clientWide-2*margin), maxDetails)
	}
	if high != w.detailsHigh || always {
		w.detailsHigh = high
		w.scale(w.dpi, nil)
	}
}

// lineOf is the height of a line of the font, in the screen's pixels.
func (w *window) lineOf(font uintptr) int32 {
	dc := call(user32, "GetDC", w.hwnd)
	defer call(user32, "ReleaseDC", w.hwnd, dc)
	before := call(gdi32, "SelectObject", dc, font)
	defer call(gdi32, "SelectObject", dc, before)
	var metrics [64]byte // TEXTMETRICW, whose first field is the height
	call(gdi32, "GetTextMetricsW", dc, uintptr(unsafe.Pointer(&metrics[0])))
	return *(*int32)(unsafe.Pointer(&metrics[0]))
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
	if w.fieldBrush != 0 {
		call(gdi32, "DeleteObject", w.fieldBrush)
	}
	w.fieldBrush = call(gdi32, "CreateSolidBrush", colorref(w.colours.card))
	if w.field != 0 {
		call(user32, "InvalidateRect", w.field, 0, 1)
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
	old := []uintptr{w.font, w.bold}
	w.dpi = dpi
	w.font, w.bold = w.makeFont(10, 400), w.makeFont(15, 600)
	if w.field != 0 {
		call(user32, "SendMessageW", w.field, 0x0030, w.font, 0) // WM_SETFONT, before the old font goes
	}
	for _, font := range old {
		if font != 0 {
			call(gdi32, "DeleteObject", font)
		}
	}
	w.lineHigh = w.lineOf(w.font)
	w.noteHigh = 0 // a word can go to another line at another scale
	for _, key := range noteTexts {
		w.noteHigh = max(w.noteHigh, w.measure(text(key), clientWide-2*inside))
	}
	w.noteHigh += 10
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
	frame := rect{0, 0, w.px(clientWide), w.px(w.high())}
	if !has(user32, "AdjustWindowRectExForDpi") ||
		call(user32, "AdjustWindowRectExForDpi", uintptr(unsafe.Pointer(&frame)), windowStyle, 0, 0, uintptr(dpi)) == 0 {
		call(user32, "AdjustWindowRectEx", uintptr(unsafe.Pointer(&frame)), windowStyle, 0, 0)
	}
	moving, left, top := uintptr(noMove), int32(0), int32(0)
	if place != nil { // where Windows suggests, on the new screen; the size is the window's own, as the note's may differ
		moving, left, top = 0, place.left, place.top
	}
	call(user32, "SetWindowPos", w.hwnd, 0, uintptr(left), uintptr(top), uintptr(frame.right-frame.left),
		uintptr(frame.bottom-frame.top), moving|noZOrder|noActivate)
	w.placeField()
	call(user32, "InvalidateRect", w.hwnd, 0, 0)
}

// placeField puts the address field in its box, or hides it with the advanced settings.
func (w *window) placeField() {
	if w.field == 0 {
		return
	}
	if !w.advanced {
		if call(user32, "GetFocus") == w.field {
			call(user32, "SetFocus", w.hwnd)
		}
		call(user32, "ShowWindow", w.field, 0) // SW_HIDE
		return
	}
	box := w.px(rowHigh - 10)
	call(user32, "SetWindowPos", w.field, 0, uintptr(w.px(fieldLeft+10)), uintptr(w.px(moreTop+5)+(box-w.lineHigh)/2),
		uintptr(w.px(fieldWide-20)), uintptr(w.lineHigh), 0x0004|0x0010|0x0040) // SWP_NOZORDER | SWP_NOACTIVATE | SWP_SHOWWINDOW
}

// fieldText is what the address field holds.
func (w *window) fieldText() string {
	buf := make([]uint16, call(user32, "GetWindowTextLengthW", w.field)+1)
	call(user32, "GetWindowTextW", w.field, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)))
	return syscall.UTF16ToString(buf)
}

func (w *window) setFieldText(s string) {
	call(user32, "SetWindowTextW", w.field, uintptr(unsafe.Pointer(utf16(s))))
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
	// The address field: WS_CHILD | ES_AUTOHSCROLL, without a border, laid in a box the window draws. It shows with
	// the advanced settings, empty for the RookieLedger site: what empty means is said below it, not inside it, where
	// it would pass for an address already filled in.
	w.address = w.s.st.customURL()
	w.field = call(user32, "CreateWindowExW", 0, uintptr(unsafe.Pointer(utf16("EDIT"))), uintptr(unsafe.Pointer(utf16(w.address))),
		0x40000000|0x0080, 0, 0, 0, 0, w.hwnd, fieldID, instance, 0)
	call(user32, "SendMessageW", w.field, 0x00C5, 512, 0) // EM_LIMITTEXT
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
		tip += ": " + text("server") + " " + text(siteState(v))
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

// menu is the icon's: show or hide the window, and quit. The settings are in the window.
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

// shapes draws what has curves, with smooth edges: the cards, the buttons, the switches, the heading's picture and
// the status dot. Sizes are in the screen's own pixels. GDI+ takes whole numbers through these calls, which is all
// that is needed here.
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
	disc := func(colour uint32, x, y, size int32) {
		fill(colour, func(brush uintptr) {
			call(gdiplus, "GdipFillEllipseI", g, brush, uintptr(x), uintptr(y), uintptr(size), uintptr(size))
		})
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
	card := func(top, high int32) {
		x, y, wide, high, r := w.px(margin), w.px(top), w.px(clientWide-2*margin), w.px(high), w.px(8)
		round(w.colours.edge, x, y, wide, high, r)
		round(w.colours.card, x+1, y+1, wide-2, high-2, r-1)
	}
	// A button, the drop-down list or the address field, as Windows 11 draws plain ones: the card's colours, a shade
	// darker under the pointer (which = 0: never).
	plain := func(which int, left, top, wide, high int32) {
		face := w.colours.card
		if which != 0 && w.hover == which {
			face = w.colours.rule
		}
		round(w.colours.edge, w.px(left), w.px(top), w.px(wide), w.px(high), w.px(5))
		round(face, w.px(left)+1, w.px(top)+1, w.px(wide)-2, w.px(high)-2, w.px(5)-1)
	}
	// An arrow of two strokes that meet at the tip, below it or (up) above it, in the screen's pixels.
	arrow := func(tip point, up bool) {
		var pen uintptr
		if call(gdiplus, "GdipCreatePen1", argb(w.colours.dim), uintptr(math.Float32bits(float32(w.px(3))/2)), 2, // in pixels
			uintptr(unsafe.Pointer(&pen))) != 0 {
			return
		}
		rise := w.px(4)
		if up {
			rise = -rise
		}
		for _, side := range []int32{-1, 1} {
			call(gdiplus, "GdipDrawLineI", g, pen, uintptr(tip.x+side*w.px(4)), uintptr(tip.y-rise), uintptr(tip.x), uintptr(tip.y))
		}
		call(gdiplus, "GdipDeletePen", pen)
	}
	// A switch at the right of a row: a filled pill with its knob at the right when on, an outline with its knob at
	// the left when off.
	toggle := func(on bool, top int32) {
		x, y, wide, high, knob := w.px(switchLeft), w.px(top+(rowHigh-switchHigh)/2), w.px(switchWide), w.px(switchHigh), w.px(12)
		if on {
			round(w.colours.accent, x, y, wide, high, high/2)
			disc(w.colours.knob, x+wide-high/2-knob/2, y+(high-knob)/2, knob)
			return
		}
		round(w.colours.dim, x, y, wide, high, high/2)
		round(w.colours.card, x+1, y+1, wide-2, high-2, high/2-1)
		disc(w.colours.dim, x+high/2-knob/2, y+(high-knob)/2, knob)
	}

	card(cardTop, rows*rowHigh)
	plain(onFolder, margin, buttonTop, buttonWide, buttonHigh)
	plain(onMore, moreLeft, buttonTop, moreWide, buttonHigh)
	tip := point{w.px(moreLeft + moreWide - 18), w.px(buttonTop+buttonHigh/2) + w.px(2)}
	if w.advanced {
		tip.y -= w.px(4)
	}
	arrow(tip, w.advanced)
	plain(onList, column, listTop, listWide, listHigh)
	arrow(point{w.px(column + listWide - 18), w.px(listTop+listHigh/2) + w.px(2)}, false)
	if w.store {
		plain(onStart, clientWide-inside-startWide, startTop+5, startWide, listHigh)
	} else {
		toggle(w.s.st.autostart(), startTop)
	}
	if w.advanced {
		card(moreTop, w.moreHigh())
		plain(0, fieldLeft, moreTop+5, fieldWide, rowHigh-10)
		// Windows 11 marks the field typed in with a line of its colour; the field the note finds fault with, in red.
		line := uint32(0)
		if _, problem := w.note(); problem {
			line = w.colours.down
		} else if call(user32, "GetFocus") == w.field {
			line = w.colours.accent
		}
		if line != 0 {
			round(line, w.px(fieldLeft)+1, w.px(moreTop+rowHigh-5)-w.px(2), w.px(fieldWide)-2, w.px(2), 0)
		}
		plain(onSave, saveLeft, moreTop+5, saveWide, rowHigh-10)
		toggle(w.s.st.debug(), w.debugTop())
	}
	if w.picture != 0 {
		call(gdiplus, "GdipDrawImageRectI", g, w.picture, uintptr(w.px(margin)), uintptr(w.px(22)), uintptr(w.px(44)), uintptr(w.px(44)))
	}
	size := w.px(10)
	disc(dot, w.px(column), w.px(cardTop)+(w.px(rowHigh)-size)/2, size)
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
	if !v.Checked.IsZero() && !w.s.pointing() {
		state, dot = text(siteState(v)), w.colours.down
		if !v.Wrong { // that one says enough, and is long
			state += " (" + v.Checked.Format("15:04") + ")"
		}
		if v.Up {
			dot = w.colours.up
		}
	}
	w.shapes(dc, dot)

	call(gdi32, "SetBkMode", dc, 1) // TRANSPARENT
	const (
		single = 0x0020 | 0x8000 // DT_SINGLELINE | DT_END_ELLIPSIS
		middle = single | 0x0004 // DT_VCENTER
		centre = middle | 0x0001 // DT_CENTER
		right  = middle | 0x0002 // DT_RIGHT
	)
	write := func(s string, font uintptr, colour uint32, x, y, wide, high int32, flags uintptr) {
		call(gdi32, "SelectObject", dc, font)
		call(gdi32, "SetTextColor", dc, colorref(colour))
		box := rect{w.px(x), w.px(y), w.px(x + wide), w.px(y + high)}
		text, _ := syscall.UTF16FromString(s)
		call(user32, "DrawTextW", dc, uintptr(unsafe.Pointer(&text[0])), uintptr(len(text)-1),
			uintptr(unsafe.Pointer(&box)), flags|0x0800) // DT_NOPREFIX
	}
	rule := func(top int32) {
		block(w.colours.rule, rect{w.px(inside), w.px(top), w.px(clientWide - inside), w.px(top) + 1})
	}
	// A row whose value is a switch: its name, then On or Off before the switch.
	switchRow := func(name string, on bool, top int32) {
		write(name, w.font, w.colours.dim, inside, top, stateLeft-inside-8, rowHigh, middle)
		write(text(map[bool]string{true: "on", false: "off"}[on]), w.font, w.colours.ink, stateLeft, top, stateWide, rowHigh, right)
	}
	const heading = margin + 44 + 14 // beside the picture
	write(appTitle, w.bold, w.colours.ink, heading, 20, clientWide-margin-heading, 28, middle)
	write(version, w.font, w.colours.dim, heading, 48, clientWide-margin-heading, 20, middle)

	last := text("never")
	if !v.LastSync.IsZero() {
		last = v.LastSync.Local().Format(text("date"))
	}
	data, foot := "…", text("uploads")
	switch {
	case v.Files == 0:
		data, foot = text("nodata"), text("hint")
	case v.Files > 0:
		data = fmt.Sprintf(text("accounts"), v.Files)
	}
	for i, row := range [rows - 1][2]string{{text("server"), state}, {text("lastsync"), last}, {text("gamedata"), data},
		{text("checkevery"), pollLabel(w.s.st.pollMinutes())}} {
		top := int32(cardTop + i*rowHigh)
		if i > 0 {
			rule(top)
		}
		value, wide := int32(column), int32(clientWide-inside-column)
		switch i {
		case 0:
			value, wide = value+18, wide-18 // after the dot
		case rows - 2:
			value, wide = value+12, wide-12-30 // inside the list, before its arrow
		}
		write(row[0], w.font, w.colours.dim, inside, top, column-inside-8, rowHigh, middle)
		write(row[1], w.font, w.colours.ink, value, top, wide, rowHigh, middle)
	}
	rule(startTop)
	if w.store {
		write(text("autostart"), w.font, w.colours.dim, inside, startTop, clientWide-inside-startWide-inside-8, rowHigh, middle)
		write(text("opensettings"), w.font, w.colours.ink, clientWide-inside-startWide, startTop+5, startWide, listHigh, centre)
	} else {
		switchRow(text("autostart"), w.s.st.autostart(), startTop)
	}
	write(text("choose"), w.font, w.colours.ink, margin, buttonTop, buttonWide, buttonHigh, centre)
	write(text("advanced"), w.font, w.colours.ink, moreLeft+8, buttonTop, moreWide-8-28, buttonHigh, centre)
	write(foot, w.font, w.colours.dim, margin, footTop, clientWide-2*margin, footHigh, 0x0010) // DT_WORDBREAK
	if !w.advanced {
		return
	}
	write(text("address"), w.font, w.colours.dim, inside, moreTop, fieldLeft-inside-8, rowHigh, middle)
	write(text("save"), w.font, w.colours.ink, saveLeft, moreTop+5, saveWide, rowHigh-10, centre)
	note, problem := w.note()
	colour := w.colours.dim
	if problem {
		colour = w.colours.down
	}
	write(note, w.font, colour, inside, noteTop, clientWide-2*inside, w.noteHigh, 0x0010|0x2000) // as measured
	rule(w.debugTop())
	switchRow(text("debug"), w.s.st.debug(), w.debugTop())
	rule(w.logTop())
	logPath := w.s.logPath
	if logPath == "" {
		logPath = "–"
	}
	write(text("log"), w.font, w.colours.dim, inside, w.logTop(), fieldLeft-inside-8, rowHigh, middle)
	write(logPath, w.font, w.colours.ink, fieldLeft, w.logTop(), clientWide-inside-fieldLeft, rowHigh,
		middle&^0x8000|0x4000) // DT_PATH_ELLIPSIS: the file's name stays in sight
	if w.detailsHigh > 0 {
		// DT_WORDBREAK | DT_EDITCONTROL: a folder's path has no space to break at, and is broken where the line ends.
		write(w.s.details(), w.font, w.colours.dim, margin, w.detailsTop(), clientWide-2*margin, w.detailsHigh, 0x0010|0x2000)
	}
}

// siteState is what the window says of the site once asked: the key of its text.
func siteState(v view) string {
	switch {
	case v.Up:
		return "up"
	case v.Wrong:
		return "wrongsite"
	}
	return "down"
}

// under tells what a mouse message's place (its lParam) is on: a button, the drop-down list, a switch (with its On
// or Off), the address field's box (onField), or nothing (0).
func (w *window) under(lParam uintptr) int {
	x, y := int32(int16(lParam&0xffff)), int32(int16(lParam>>16&0xffff))
	within := func(left, top, wide, high int32) bool {
		return x >= w.px(left) && x < w.px(left+wide) && y >= w.px(top) && y < w.px(top+high)
	}
	switch {
	case within(margin, buttonTop, buttonWide, buttonHigh):
		return onFolder
	case within(moreLeft, buttonTop, moreWide, buttonHigh):
		return onMore
	case within(column, listTop, listWide, listHigh):
		return onList
	case w.store && within(clientWide-inside-startWide, startTop+5, startWide, listHigh),
		!w.store && within(stateLeft, startTop, clientWide-inside-stateLeft, rowHigh):
		return onStart
	case !w.advanced:
		return 0
	case within(fieldLeft, moreTop+5, fieldWide, rowHigh-10):
		return onField
	case within(saveLeft, moreTop+5, saveWide, rowHigh-10):
		return onSave
	case within(stateLeft, w.debugTop(), clientWide-inside-stateLeft, rowHigh):
		return onDebug
	}
	return 0
}

// pointer follows the mouse over the window: a button or the list shows that it is under it.
func (w *window) pointer(over int) {
	if over == w.hover {
		return
	}
	w.hover = over
	if over != 0 { // to be told when the pointer leaves the window without crossing the rest of it
		track := struct {
			size, flags uint32
			hwnd        uintptr
			hoverTime   uint32
		}{flags: 2, hwnd: w.hwnd} // TME_LEAVE
		track.size = uint32(unsafe.Sizeof(track))
		call(user32, "TrackMouseEvent", uintptr(unsafe.Pointer(&track)))
	}
	call(user32, "InvalidateRect", w.hwnd, 0, 0)
}

// choosePoll opens the drop-down list below its box: how often the saved files are looked at, the choice in use
// marked. The choice made is remembered and holds from now on, starting with a look at once.
func (w *window) choosePoll() {
	menu := call(user32, "CreatePopupMenu")
	defer call(user32, "DestroyMenu", menu)
	now := w.s.st.pollMinutes()
	for i, minutes := range pollChoices {
		call(user32, "AppendMenuW", menu, 0, uintptr(menuPoll+i), uintptr(unsafe.Pointer(utf16(pollLabel(minutes)))))
		if minutes == now {
			call(user32, "CheckMenuRadioItem", menu, menuPoll, uintptr(menuPoll+len(pollChoices)-1), uintptr(menuPoll+i), 0) // by command
		}
	}
	at := point{w.px(column), w.px(listTop + listHigh)}
	call(user32, "ClientToScreen", w.hwnd, uintptr(unsafe.Pointer(&at)))
	// TPM_RETURNCMD: the choice comes back here, not as a message.
	chosen := int(call(user32, "TrackPopupMenu", menu, 0x0100, uintptr(at.x), uintptr(at.y), 0, w.hwnd, 0)) - menuPoll
	// A click on the list's own box closes the list, and Windows then hands that click to the window: it is taken
	// away, or it would open the list again.
	var click msg
	if call(user32, "PeekMessageW", uintptr(unsafe.Pointer(&click)), w.hwnd, wmLDown, wmLDown, 0) != 0 && // PM_NOREMOVE
		w.under(click.lParam) == onList {
		call(user32, "PeekMessageW", uintptr(unsafe.Pointer(&click)), w.hwnd, wmLDown, wmLDown, 1) // PM_REMOVE
	}
	if chosen < 0 || chosen >= len(pollChoices) || pollChoices[chosen] == now {
		return
	}
	st := w.s.st
	st.change(func() { st.PollMinutes = pollChoices[chosen] })
	w.s.save()
	w.s.look(false)
	call(user32, "InvalidateRect", w.hwnd, 0, 0)
}

// chooseFolder asks the person where their World of Warcraft folder is, with Windows' own dialog, and has the
// watching loop look there at once. It is what --wow-dir does, for who never opens a terminal.
func (w *window) chooseFolder() {
	if w.choosing {
		return // one dialog at a time
	}
	w.choosing = true
	picked, ok := pickFolder(w.hwnd, text("choosetitle"))
	w.choosing = false
	if !ok {
		return
	}
	root, ok := installFrom(picked)
	if !ok {
		message := fmt.Sprintf(text("notforever"), picked)
		if flavors := otherFlavors(picked); flavors != "" {
			message += "\n\n" + fmt.Sprintf(text("dotherflavor"), picked, flavors)
		}
		notify(message)
		return
	}
	st := w.s.st
	st.change(func() { st.WowDirs = []string{root} })
	w.s.save()
	log.Printf("game folder chosen: %s", root)
	w.s.look(true)
}

type guid struct {
	a    uint32
	b, c uint16
	d    [8]byte
}

var (
	clsidFileOpenDialog = guid{0xDC1C5A9C, 0xE88A, 0x4DDE, [8]byte{0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7}}
	iidFileOpenDialog   = guid{0xD57C7288, 0xD4AD, 0x4768, [8]byte{0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60}}
)

// peek reads the pointer-sized value at an address Windows gave.
func peek(address uintptr) uintptr {
	var value uintptr
	call(kernel32, "RtlMoveMemory", uintptr(unsafe.Pointer(&value)), address, unsafe.Sizeof(value))
	return value
}

// method calls the n-th function of a COM object (counted from 0, as its interface lists them) and tells whether
// it succeeded: an HRESULT is 32 bits, negative for a failure, and "cancelled" is one. Its arguments are kept in
// place as call's are.
//
//go:uintptrescapes
func method(object uintptr, n uintptr, args ...uintptr) bool {
	function := peek(peek(object) + n*unsafe.Sizeof(object))
	result, _, _ := syscall.SyscallN(function, append([]uintptr{object}, args...)...)
	return int32(result) >= 0
}

// The functions used, by their place in IFileOpenDialog and in IShellItem.
const (
	comRelease         = 2
	dialogShow         = 3
	dialogSetOptions   = 9
	dialogGetOptions   = 10
	dialogSetTitle     = 17
	dialogGetResult    = 20
	itemGetDisplayName = 5
)

// folderDialog makes Windows' dialog for opening a file, set to pick a folder of the disk: the one every program
// shows since Windows Vista, with the address bar, the search and the person's pinned folders. Zero when Windows
// gives none; the caller releases it.
func folderDialog(title string) uintptr {
	call(ole32, "CoInitializeEx", 0, 2) // COINIT_APARTMENTTHREADED, for this thread; asking twice does no harm
	var dialog uintptr
	if int32(call(ole32, "CoCreateInstance", uintptr(unsafe.Pointer(&clsidFileOpenDialog)), 0, 1, // CLSCTX_INPROC_SERVER
		uintptr(unsafe.Pointer(&iidFileOpenDialog)), uintptr(unsafe.Pointer(&dialog)))) < 0 || dialog == 0 {
		return 0
	}
	var options uint32
	method(dialog, dialogGetOptions, uintptr(unsafe.Pointer(&options)))
	// FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST
	if !method(dialog, dialogSetOptions, uintptr(options|0x20|0x40|0x800)) {
		method(dialog, comRelease)
		return 0
	}
	method(dialog, dialogSetTitle, uintptr(unsafe.Pointer(utf16(title))))
	return dialog
}

// pickFolder shows that dialog over the window and returns the folder picked, or false when the person gave up.
func pickFolder(owner uintptr, title string) (string, bool) {
	dialog := folderDialog(title)
	if dialog == 0 {
		return "", false
	}
	defer method(dialog, comRelease)
	if !method(dialog, dialogShow, owner) {
		return "", false
	}
	var item uintptr
	if !method(dialog, dialogGetResult, uintptr(unsafe.Pointer(&item))) || item == 0 {
		return "", false
	}
	defer method(item, comRelease)
	var name uintptr                                                                                // a text Windows allocated: copied, then given back
	if !method(item, itemGetDisplayName, 0x80058000, uintptr(unsafe.Pointer(&name))) || name == 0 { // SIGDN_FILESYSPATH
		return "", false
	}
	defer call(ole32, "CoTaskMemFree", name)
	path := make([]uint16, call(kernel32, "lstrlenW", name)+1)
	call(kernel32, "RtlMoveMemory", uintptr(unsafe.Pointer(&path[0])), name, uintptr(len(path)*2))
	return syscall.UTF16ToString(path), true
}

// setAutostart is the switch of the card's last row. For the Store package, Windows holds the switch: the row's
// button opens its page.
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

// setDebug is the switch of the advanced settings: the window grows by the details, or gives them up, and the log
// holds them or not.
func (w *window) setDebug() {
	st := w.s.st
	st.change(func() { st.Debug = !st.Debug })
	w.s.save()
	w.fit(true)
}

// openAdvanced opens or closes the advanced settings. Closed, the field drops what was typed in it and not saved.
func (w *window) openAdvanced() {
	w.advanced = !w.advanced
	if !w.advanced {
		w.setFieldText(w.address)
		w.fieldError = ""
	}
	w.fit(true)
}

// typeAddress puts the caret in the address field: a click on its box beside the field itself.
func (w *window) typeAddress() { call(user32, "SetFocus", w.field) }

// saveAddress takes the address typed in the field, with Enter or the Save button: the watching loop uploads there
// from its next pass, which comes at once, and the note below the field says how the address answers. An address
// it does not take is said there, beside it, and left in the field to be put right. Empty is the RookieLedger site.
func (w *window) saveAddress() {
	address, err := siteAddress(w.fieldText())
	if err != nil {
		w.fieldError = text("needhttps")
		call(user32, "InvalidateRect", w.hwnd, 0, 0)
		return
	}
	w.setFieldText(address)
	w.fieldError = ""
	if address != w.address {
		w.address = address
		w.s.point(address)
	}
	call(user32, "SetFocus", w.hwnd)
	call(user32, "InvalidateRect", w.hwnd, 0, 0)
}

// note is what the window says below the address field, and whether it is a problem: why what was typed was not
// taken, how the address saved answers, or, for the RookieLedger site, what an empty field means.
func (w *window) note() (string, bool) {
	v := w.s.view()
	switch {
	case w.fieldError != "":
		return w.fieldError, true
	case w.address == "":
		return text("addresshelp"), false
	case v.Checked.IsZero() || w.s.pointing(): // until the loop takes it, the view still holds the old address's answer
		return text("addresschecking"), false
	case v.Up:
		return text("addressok"), false
	case v.Wrong:
		return text("addresswrong"), true
	}
	return text("addressdown"), true
}

// key takes the keys the address field gives no meaning to: Enter saves, Escape puts back the address saved, and
// Ctrl+A selects all. It tells whether the key was taken.
func (w *window) key(code uintptr) bool {
	switch {
	case code == 0x0D: // VK_RETURN
		w.saveAddress()
	case code == 0x1B: // VK_ESCAPE
		w.setFieldText(w.address)
		w.fieldError = ""
		call(user32, "SetFocus", w.hwnd)
	case code == 'A' && int16(call(user32, "GetKeyState", 0x11)) < 0: // VK_CONTROL held
		call(user32, "SendMessageW", w.field, 0x00B1, 0, ^uintptr(0)) // EM_SETSEL, all of it
	default:
		return false
	}
	return true
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
		if lParam != 0 && lParam == w.field {
			switch wParam >> 16 & 0xffff {
			case 0x0100, 0x0200: // EN_SETFOCUS, EN_KILLFOCUS: the line below the field shows the focus
				call(user32, "InvalidateRect", hwnd, 0, 0)
			case 0x0300: // EN_CHANGE: what is typed anew is judged when it is saved
				if w.fieldError != "" && call(user32, "GetFocus") == w.field {
					w.fieldError = ""
					call(user32, "InvalidateRect", hwnd, 0, 0)
				}
			}
			break
		}
		switch wParam & 0xffff {
		case menuToggle:
			w.toggle()
		case menuQuit:
			call(user32, "DestroyWindow", hwnd)
		}
	case wmEditBg:
		if lParam != w.field {
			return call(user32, "DefWindowProcW", hwnd, uintptr(message), wParam, lParam)
		}
		call(gdi32, "SetTextColor", wParam, colorref(w.colours.ink))
		call(gdi32, "SetBkColor", wParam, colorref(w.colours.card))
		return w.fieldBrush
	case wmMove:
		w.pointer(w.under(lParam))
	case wmLeave:
		w.pointer(0)
		w.pressed = 0
	case wmLDown:
		w.pressed = w.under(lParam)
		// A click elsewhere leaves the address field, as in every window; what was typed stays until saved.
		if w.pressed != onField && w.pressed != onSave && call(user32, "GetFocus") == w.field {
			call(user32, "SetFocus", hwnd)
		}
	case wmLButton:
		// A click is the button going down and coming up on the same thing: a button that comes up here after it
		// went down elsewhere (a drag let go of, the click that closed a menu or started the program) is none.
		pressed := w.pressed
		w.pressed = 0
		if w.under(lParam) != pressed {
			break
		}
		switch pressed {
		case onFolder:
			w.chooseFolder()
		case onList:
			w.choosePoll()
		case onStart:
			w.setAutostart()
		case onMore:
			w.openAdvanced()
		case onField:
			w.typeAddress()
		case onSave:
			w.saveAddress()
		case onDebug:
			w.setDebug()
		}
	case wmCursor:
		if w.hover == 0 || lParam&0xffff != 1 { // HTCLIENT: the pointer is inside the window, not on its frame
			return call(user32, "DefWindowProcW", hwnd, uintptr(message), wParam, lParam)
		}
		cursor := uintptr(32649) // IDC_HAND
		if w.hover == onField {
			cursor = 32513 // IDC_IBEAM
		}
		call(user32, "SetCursor", call(user32, "LoadCursorW", 0, cursor))
		return 1
	case msgChange:
		w.tray(1) // NIM_MODIFY
		w.fit(false)
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
		// Enter and Escape in the address field are the window's: taken before they become characters, which a field
		// of one line answers with a beep.
		if m.hwnd == w.field && m.message == wmKeyDown && w.key(m.wParam) {
			continue
		}
		call(user32, "TranslateMessage", uintptr(unsafe.Pointer(&m)))
		call(user32, "DispatchMessageW", uintptr(unsafe.Pointer(&m)))
	}
}

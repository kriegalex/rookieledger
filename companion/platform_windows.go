//go:build windows

package main

import (
	"errors"
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
	"unsafe"
)

// A double-click is the whole installation on Windows, and every start repairs it: wherever the program is started
// from (the Downloads folder, a folder a zip was opened in), it copies itself to installedExe, points the Run key
// there and starts that copy. The file a member downloaded can then be moved or deleted, and a newer download
// replaces the installed copy the same way.

// The Run key only starts the program at the next logon, so the installing process keeps running.
const installHandsOver = false

const (
	runKey    = `Software\Microsoft\Windows\CurrentVersion\Run` // under HKEY_CURRENT_USER
	runValue  = "RookieLedgerSync"
	exeName   = "RookieLedgerSync.exe"
	mutexName = `Local\RookieLedgerSync` // Local: one per logon session, so two users of one PC do not meet
)

var (
	kernel32 = syscall.NewLazyDLL("kernel32.dll")
	advapi32 = syscall.NewLazyDLL("advapi32.dll")
	user32   = syscall.NewLazyDLL("user32.dll")
	gdi32    = syscall.NewLazyDLL("gdi32.dll")
	shell32  = syscall.NewLazyDLL("shell32.dll")
)

func hidden(name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	return cmd
}

// regString reads a text value through the registry API. reg.exe prints in the console code page, which turns
// "D:\Jeux vidéo" into bytes no file name matches.
func regString(root syscall.Handle, path, name string) (string, bool) {
	p, err := syscall.UTF16PtrFromString(path)
	if err != nil {
		return "", false
	}
	n, err := syscall.UTF16PtrFromString(name)
	if err != nil {
		return "", false
	}
	var key syscall.Handle
	if syscall.RegOpenKeyEx(root, p, 0, syscall.KEY_READ, &key) != nil {
		return "", false
	}
	defer syscall.RegCloseKey(key)
	var kind, size uint32
	if syscall.RegQueryValueEx(key, n, nil, &kind, nil, &size) != nil || size == 0 ||
		(kind != syscall.REG_SZ && kind != syscall.REG_EXPAND_SZ) {
		return "", false
	}
	buf := make([]uint16, size/2+1) // size is in bytes; the text may come without its closing zero
	if syscall.RegQueryValueEx(key, n, nil, &kind, (*byte)(unsafe.Pointer(&buf[0])), &size) != nil {
		return "", false
	}
	return syscall.UTF16ToString(buf), true
}

// platformRoots lists where a "World of Warcraft" folder usually is: the path Battle.net recorded, then common folders
// on every drive.
func platformRoots() []string {
	var out []string
	for _, key := range []string{`SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft`,
		`SOFTWARE\Blizzard Entertainment\World of Warcraft`} {
		if path, ok := regString(syscall.HKEY_LOCAL_MACHINE, key, "InstallPath"); ok {
			// InstallPath names one flavor's folder (…\World of Warcraft\_retail_\).
			path = strings.TrimRight(strings.TrimSpace(path), `\`)
			if path != "" {
				out = append(out, path, filepath.Dir(path))
			}
		}
	}
	for drive := 'C'; drive <= 'Z'; drive++ {
		for _, sub := range []string{`World of Warcraft`, `Program Files (x86)\World of Warcraft`,
			`Program Files\World of Warcraft`, `Games\World of Warcraft`, `Battle.net\World of Warcraft`,
			`Blizzard\World of Warcraft`, `Jeux\World of Warcraft`} {
			out = append(out, string(drive)+`:\`+sub)
		}
	}
	return out
}

// installedExe is where the copy that starts with the session lives: %LocalAppData%\RookieLedgerSync.
func installedExe() (string, error) {
	dir, err := os.UserCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "RookieLedgerSync", exeName), nil
}

func samePath(a, b string) bool {
	if ia, err := os.Stat(a); err == nil {
		if ib, err := os.Stat(b); err == nil {
			return os.SameFile(ia, ib)
		}
	}
	return strings.EqualFold(filepath.Clean(a), filepath.Clean(b))
}

func copyFile(from, to string) error {
	in, err := os.Open(from)
	if err != nil {
		return err
	}
	defer in.Close()
	tmp := to + ".new"
	out, err := os.OpenFile(tmp, os.O_CREATE|os.O_TRUNC|os.O_WRONLY, 0o755)
	if err != nil {
		return err
	}
	_, err = io.Copy(out, in)
	if closeErr := out.Close(); err == nil {
		err = closeErr
	}
	if err == nil {
		err = os.Rename(tmp, to)
	}
	if err != nil {
		_ = os.Remove(tmp)
	}
	return err
}

func pidFile(dir string) string { return filepath.Join(dir, "pid") }

// stopRunning ends the copy that noted its process id in the config folder, if it still runs under our name.
func stopRunning(dir string) {
	data, err := os.ReadFile(pidFile(dir))
	if err != nil {
		return
	}
	pid, err := strconv.Atoi(strings.TrimSpace(string(data)))
	if err != nil || pid <= 0 || pid == os.Getpid() {
		return
	}
	if askToQuit() {
		time.Sleep(500 * time.Millisecond) // asked first, so that its tray icon goes with it
	}
	_ = hidden("taskkill", "/F", "/PID", strconv.Itoa(pid), "/FI", "IMAGENAME eq "+exeName).Run()
	_ = os.Remove(pidFile(dir))
}

// installCopy puts this program at target, replacing a copy that may be running.
func installCopy(dir, self, target string) error {
	if err := os.MkdirAll(filepath.Dir(target), 0o755); err != nil {
		return err
	}
	stopRunning(dir)
	var err error
	for try := 0; try < 10; try++ { // a stopped copy lets go of its file a moment later
		if err = copyFile(self, target); err == nil {
			return nil
		}
		time.Sleep(300 * time.Millisecond)
	}
	// Still held: a running program's file cannot be overwritten, but it can be renamed out of the way.
	old := target + ".old"
	_ = os.Remove(old)
	if os.Rename(target, old) == nil {
		err = copyFile(self, target)
	}
	return err
}

// runKeyValue opens the Run key of this user for writing and hands it, with the value's name, to f.
func runKeyValue(f func(key syscall.Handle, name *uint16) uintptr) error {
	path, _ := syscall.UTF16PtrFromString(runKey)
	name, _ := syscall.UTF16PtrFromString(runValue)
	var key syscall.Handle
	// Created when missing: the key is there on every Windows, not in every sandbox.
	if code, _, _ := advapi32.NewProc("RegCreateKeyExW").Call(uintptr(syscall.HKEY_CURRENT_USER), uintptr(unsafe.Pointer(path)),
		0, 0, 0, syscall.KEY_SET_VALUE, 0, uintptr(unsafe.Pointer(&key)), 0); code != 0 {
		return syscall.Errno(code)
	}
	defer syscall.RegCloseKey(key)
	if code := f(key, name); code != 0 {
		return syscall.Errno(code)
	}
	return nil
}

func registerRun(exe string) error {
	// --background: the session starts the program without opening its window.
	data, err := syscall.UTF16FromString(`"` + exe + `" --background`)
	if err != nil {
		return err
	}
	return runKeyValue(func(key syscall.Handle, name *uint16) uintptr {
		code, _, _ := advapi32.NewProc("RegSetValueExW").Call(uintptr(key), uintptr(unsafe.Pointer(name)), 0,
			syscall.REG_SZ, uintptr(unsafe.Pointer(&data[0])), uintptr(len(data)*2))
		return code
	})
}

func unregisterRun() error {
	err := runKeyValue(func(key syscall.Handle, name *uint16) uintptr {
		code, _, _ := advapi32.NewProc("RegDeleteValueW").Call(uintptr(key), uintptr(unsafe.Pointer(name)))
		return code
	})
	if errors.Is(err, syscall.ERROR_FILE_NOT_FOUND) {
		err = nil // it was not there
	}
	return err
}

// setAutostart follows the setting of the window's menu: the Run key names this running copy, or nothing does.
// Not for the Store package, whose start with the session is Windows' to switch (openStartupSettings).
func setAutostart(on bool) error {
	if !on {
		return unregisterRun()
	}
	self, err := os.Executable()
	if err != nil {
		return err
	}
	return registerRun(self)
}

// openStartupSettings shows the page of Windows' settings that lists what starts with the session: where the
// Store package's start is switched on and off.
func openStartupSettings() {
	verb, _ := syscall.UTF16PtrFromString("open")
	page, _ := syscall.UTF16PtrFromString("ms-settings:startupapps")
	shell32.NewProc("ShellExecuteW").Call(0, uintptr(unsafe.Pointer(verb)), uintptr(unsafe.Pointer(page)), 0, 0, 1)
}

func installAutostart() error {
	exe, err := installedExe()
	if err != nil {
		return err
	}
	return registerRun(exe)
}

// removeAutostart undoes the installation: the Run key, the running copy and the installed file.
func removeAutostart() error {
	err := unregisterRun()
	if dir, dirErr := os.UserConfigDir(); dirErr == nil {
		stopRunning(filepath.Join(dir, "RookieLedgerSync"))
	}
	if target, targetErr := installedExe(); targetErr == nil {
		if self, selfErr := os.Executable(); selfErr != nil || !samePath(self, target) {
			_ = os.Remove(target)
		}
	}
	return err
}

// lockInstance takes this logon session's named mutex. running is true when another copy holds it.
func lockInstance() (release func(), running bool, err error) {
	name, err := syscall.UTF16PtrFromString(mutexName)
	if err != nil {
		return func() {}, false, err
	}
	handle, _, callErr := kernel32.NewProc("CreateMutexW").Call(0, 0, uintptr(unsafe.Pointer(name)))
	if handle == 0 {
		return func() {}, false, callErr
	}
	release = func() { _ = syscall.CloseHandle(syscall.Handle(handle)) }
	if errors.Is(callErr, syscall.ERROR_ALREADY_EXISTS) {
		release()
		return func() {}, true, nil
	}
	return release, false, nil
}

// packaged tells whether the program runs from its Microsoft Store package. Windows then installs, starts and
// removes it (the package's manifest, companion/store/AppxManifest.xml, names the start with the session), and a
// package may neither copy itself elsewhere nor write the Run key: its registry writes go to a private copy.
func packaged() bool {
	var length uint32
	code, _, _ := kernel32.NewProc("GetCurrentPackageFullName").Call(uintptr(unsafe.Pointer(&length)), 0)
	return code == uintptr(syscall.ERROR_INSUFFICIENT_BUFFER) // a program outside a package gets APPMODEL_ERROR_NO_PACKAGE
}

// settle makes this process the one copy that runs for this user, started from the installed place. It returns
// false when another process is that copy: the installed one it just started, or one that already runs. With
// renewed, the start brought a setting (--url, --wow-dir): a copy that already runs is asked to leave, since it
// read its settings when it started.
func settle(dir string, st *state, renewed bool) (release func(), proceed bool) {
	self, selfErr := os.Executable()
	target, targetErr := installedExe()
	store := packaged()
	if !store && selfErr == nil && targetErr == nil && !samePath(self, target) {
		err := installCopy(dir, self, target)
		if err == nil {
			// Not hidden: a process started hidden has its first ShowWindow ignored, and its window is the point.
			err = exec.Command(target, os.Args[1:]...).Start()
		}
		if err == nil {
			// The installed copy opens its window, which says the rest, and sees to the start with the session.
			return nil, false
		}
		log.Printf("not installed to %s (%v): running from %s", target, err, self)
	}
	release, running, err := lockInstance()
	if running && renewed && askToQuit() {
		for try := 0; running && try < 25; try++ {
			time.Sleep(200 * time.Millisecond)
			release, running, err = lockInstance()
		}
	}
	if running {
		if !showRunning() {
			notify(text("running") + "\n\n" + describe(st))
		}
		return nil, false
	}
	if err != nil {
		log.Printf("no instance lock: %v", err)
	}
	// Every start puts the start with the session as the setting has it: on unless the person switched it off.
	if !store && selfErr == nil {
		if err := setAutostart(st.autostart()); err != nil {
			log.Printf("start with the session not set: %v", err)
		}
	}
	_ = os.WriteFile(pidFile(dir), []byte(strconv.Itoa(os.Getpid())), 0o600)
	return release, true
}

// notify shows a message box: the program is built without a console window, and --status has no window to use.
func notify(message string) {
	title, _ := syscall.UTF16PtrFromString("RookieLedger Sync")
	body, _ := syscall.UTF16PtrFromString(message)
	user32.NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(body)), uintptr(unsafe.Pointer(title)), 0x40)
}

func french() bool {
	lang, _, _ := kernel32.NewProc("GetUserDefaultUILanguage").Call()
	return lang&0x3ff == 0x0c
}

// setupLog sends the log to a file, the program having no console, and returns where that is.
func setupLog(path string) string {
	if info, err := os.Stat(path); err == nil && info.Size() > maxLogBytes {
		_ = os.Remove(path)
	}
	if f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600); err == nil {
		log.SetOutput(f)
		return path
	}
	log.SetOutput(io.Discard)
	return ""
}

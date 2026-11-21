//go:build windows

package main

import (
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"testing"
	"unsafe"
)

func lockForTest(string) (func(), bool, error) { return lockInstance() }

func TestRegistryTextIsReadAsText(t *testing.T) {
	got, ok := regString(syscall.HKEY_LOCAL_MACHINE, `SOFTWARE\Microsoft\Windows NT\CurrentVersion`, "ProductName")
	if !ok || got == "" {
		t.Fatalf("ProductName: %q, %v", got, ok)
	}
	if _, ok := regString(syscall.HKEY_LOCAL_MACHINE, `SOFTWARE\No Such Key Here`, "InstallPath"); ok {
		t.Fatalf("a missing key gave a value")
	}
}

func TestInstalledCopyReplacesItself(t *testing.T) {
	dir := t.TempDir()
	self := filepath.Join(dir, "Téléchargements", "RookieLedgerSync (1).exe")
	target := filepath.Join(dir, "installed", exeName)
	_ = os.MkdirAll(filepath.Dir(self), 0o755)
	if err := os.WriteFile(self, []byte("new"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, old := range []string{"", "old"} { // nothing installed yet, then an older copy
		if old != "" {
			_ = os.WriteFile(target, []byte(old), 0o755)
		}
		if err := installCopy(dir, self, target); err != nil {
			t.Fatal(err)
		}
		if data, _ := os.ReadFile(target); string(data) != "new" {
			t.Fatalf("installed copy holds %q", data)
		}
	}
	if samePath(self, target) || !samePath(target, filepath.Join(dir, "installed", "ROOKIELEDGERSYNC.EXE")) {
		t.Fatalf("samePath does not compare as Windows does")
	}
}

func TestAutostartEntry(t *testing.T) {
	exe := `C:\Users\Jérôme\AppData\Local\RookieLedgerSync\RookieLedgerSync.exe`
	if err := registerRun(exe); err != nil {
		t.Fatal(err)
	}
	if got, ok := regString(syscall.HKEY_CURRENT_USER, runKey, runValue); !ok || got != `"`+exe+`" --background` {
		t.Fatalf("Run key holds %q, %v", got, ok)
	}
	if err := removeAutostart(); err != nil {
		t.Fatal(err)
	}
	if _, ok := regString(syscall.HKEY_CURRENT_USER, runKey, runValue); ok {
		t.Fatalf("the entry is still there")
	}
	if err := removeAutostart(); err != nil {
		t.Fatalf("removing what is not installed: %v", err)
	}
}

func TestAutostartSetting(t *testing.T) {
	self, err := os.Executable()
	if err != nil {
		t.Fatal(err)
	}
	if err := setAutostart(true); err != nil {
		t.Fatal(err)
	}
	if got, ok := regString(syscall.HKEY_CURRENT_USER, runKey, runValue); !ok || got != `"`+self+`" --background` {
		t.Fatalf("switched on, the Run key holds %q, %v", got, ok)
	}
	for range 2 { // switched off, and switched off when it already is
		if err := setAutostart(false); err != nil {
			t.Fatal(err)
		}
		if _, ok := regString(syscall.HKEY_CURRENT_USER, runKey, runValue); ok {
			t.Fatalf("switched off, the entry is still there")
		}
	}
}

func TestInstallsAreLookedForOnLocalDrivesOnly(t *testing.T) {
	system := filepath.VolumeName(os.Getenv("SystemRoot")) + `\`
	if !localDrive(system) {
		t.Fatalf("%s is not taken for a local drive", system)
	}
	if localDrive(`B:\`) && localDrive(`Q:\`) && localDrive(`Y:\`) {
		t.Fatalf("drives that are not there are taken for local ones")
	}
	// The search itself runs here on a real Windows: it must come back, with folders of that name only.
	for _, root := range platformRoots() {
		if base := filepath.Base(root); base != wowFolder && !strings.HasPrefix(base, "_") {
			t.Fatalf("not a World of Warcraft folder: %s", root)
		}
	}
}

// The dialog is made as the window makes it, up to the moment it would show: Windows gives one, takes the options
// and the title, and the functions are where their numbers say.
func TestFolderDialogIsThere(t *testing.T) {
	runtime.LockOSThread() // a dialog belongs to the thread that made it
	defer runtime.UnlockOSThread()
	dialog := folderDialog("Select your World of Warcraft folder")
	if dialog == 0 {
		t.Fatal("Windows gave no folder dialog")
	}
	var options uint32
	if !method(dialog, dialogGetOptions, uintptr(unsafe.Pointer(&options))) || options&0x20 == 0 {
		t.Fatalf("the dialog does not pick folders: options %#x", options)
	}
	method(dialog, comRelease)
}

func TestTheSearchStaysOutOfHiddenAndSystemFolders(t *testing.T) {
	top := t.TempDir()
	for _, name := range []string{"Plain", "Hidden", "System"} {
		if err := os.MkdirAll(filepath.Join(top, name, wowFolder), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for name, attribute := range map[string]uint32{"Hidden": syscall.FILE_ATTRIBUTE_HIDDEN, "System": syscall.FILE_ATTRIBUTE_SYSTEM} {
		path, _ := syscall.UTF16PtrFromString(filepath.Join(top, name))
		if err := syscall.SetFileAttributes(path, attribute); err != nil {
			t.Fatal(err)
		}
	}
	got := installsBelow(top, 2)
	if len(got) != 1 || got[0] != filepath.Join(top, "Plain", wowFolder) {
		t.Fatalf("found %v", got)
	}
	// On this computer: nothing below Windows' own folder, ProgramData, AppData or a OneDrive folder is a candidate.
	windows := strings.ToLower(os.Getenv("SystemRoot")) + `\`
	for _, root := range platformRoots() {
		lower := strings.ToLower(root)
		if strings.HasPrefix(lower, windows) || strings.Contains(lower, `\programdata\`) || strings.Contains(lower, `\onedrive`) ||
			strings.Contains(lower, `\appdata\`) {
			t.Fatalf("looked where it should not: %s", root)
		}
	}
}

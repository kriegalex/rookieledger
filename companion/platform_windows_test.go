//go:build windows

package main

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
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
	if got, ok := regString(syscall.HKEY_CURRENT_USER, runKey, runValue); !ok || got != `"`+exe+`"` {
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

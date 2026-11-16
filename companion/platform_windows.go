//go:build windows

package main

import (
	"io"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"unsafe"
)

// A double-click is the whole installation on Windows.
const installOnFirstRun = true

// The Run key only starts the program at the next logon, so the installing process keeps running.
const installHandsOver = false

const runKey = `HKCU\Software\Microsoft\Windows\CurrentVersion\Run`

func hidden(name string, args ...string) *exec.Cmd {
	cmd := exec.Command(name, args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{HideWindow: true}
	return cmd
}

// platformRoots lists where a "World of Warcraft" folder usually is: the path Battle.net recorded, then common folders
// on every drive.
func platformRoots() []string {
	var out []string
	for _, key := range []string{`HKLM\SOFTWARE\WOW6432Node\Blizzard Entertainment\World of Warcraft`,
		`HKLM\SOFTWARE\Blizzard Entertainment\World of Warcraft`} {
		if data, err := hidden("reg", "query", key, "/v", "InstallPath").Output(); err == nil {
			for _, line := range strings.Split(string(data), "\n") {
				if i := strings.Index(line, "REG_SZ"); i >= 0 {
					// InstallPath names one flavor's folder (…\World of Warcraft\_retail_\).
					path := strings.TrimRight(strings.TrimSpace(line[i+len("REG_SZ"):]), `\`)
					out = append(out, path, filepath.Dir(path))
				}
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

func installAutostart() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	return hidden("reg", "add", runKey, "/v", "RookieLedgerSync", "/t", "REG_SZ", "/d", `"`+exe+`"`, "/f").Run()
}

func removeAutostart() error {
	return hidden("reg", "delete", runKey, "/v", "RookieLedgerSync", "/f").Run()
}

// notify shows a message box: the program is built without a console window.
func notify(message string) {
	title, _ := syscall.UTF16PtrFromString("RookieLedger Sync")
	body, _ := syscall.UTF16PtrFromString(message)
	syscall.NewLazyDLL("user32.dll").NewProc("MessageBoxW").Call(0, uintptr(unsafe.Pointer(body)), uintptr(unsafe.Pointer(title)), 0x40)
}

func french() bool {
	lang, _, _ := syscall.NewLazyDLL("kernel32.dll").NewProc("GetUserDefaultUILanguage").Call()
	return lang&0x3ff == 0x0c
}

func setupLog(path string) {
	if info, err := os.Stat(path); err == nil && info.Size() > maxLogBytes {
		_ = os.Remove(path)
	}
	if f, err := os.OpenFile(path, os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600); err == nil {
		log.SetOutput(f)
	} else {
		log.SetOutput(io.Discard)
	}
}

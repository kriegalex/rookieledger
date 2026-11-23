//go:build !windows

package main

import (
	"errors"
	"fmt"
	"log"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
)

// On Linux the autostart is a systemd user unit, installed only when asked (--install).

// systemd starts the unit at once, so the process that installed it has nothing left to do.
const installHandsOver = true

// noFolderText is the key of the text that says the game was not found: here --wow-dir points to it.
const noFolderText = "dnofolderflag"

const unitName = "rookieledger-sync.service"

// serve runs the watching loop. There is no window here: the journal says what the program does.
func serve(_ *syncer, _ bool, watch func()) { watch() }

// platformRoots lists where a "World of Warcraft" folder usually is under Wine, Lutris, Bottles or a games disk.
func platformRoots() []string {
	home, _ := os.UserHomeDir()
	wow := "World of Warcraft"
	prefix := filepath.Join("drive_c", "Program Files (x86)", wow)
	return []string{
		filepath.Join(home, wow), filepath.Join(home, "Games", wow), filepath.Join(home, "Games", "*", wow),
		filepath.Join(home, ".wine", prefix), filepath.Join(home, "Games", "*", prefix),
		filepath.Join(home, ".local", "share", "bottles", "bottles", "*", prefix),
		filepath.Join(home, ".var", "app", "com.usebottles.bottles", "data", "bottles", "bottles", "*", prefix),
		filepath.Join(home, ".local", "share", "Steam", "steamapps", "compatdata", "*", "pfx", prefix),
		filepath.Join("/mnt", "*", wow), filepath.Join("/mnt", "*", "*", wow), filepath.Join("/mnt", "*", "*", "*", wow),
		filepath.Join("/media", "*", "*", wow), filepath.Join("/media", "*", "*", "*", wow),
		filepath.Join("/run", "media", "*", "*", wow), filepath.Join("/run", "media", "*", "*", "*", wow),
	}
}

func unitPath() (string, error) {
	dir, err := os.UserConfigDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(dir, "systemd", "user", unitName), nil
}

func installAutostart() error {
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	path, err := unitPath()
	if err != nil {
		return err
	}
	unit := "[Unit]\nDescription=Upload the RookieLedger addon's data to its site\nAfter=network-online.target\n\n" +
		"[Service]\nExecStart=\"" + exe + "\"\nRestart=on-failure\nRestartSec=60\n\n[Install]\nWantedBy=default.target\n"
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if err := os.WriteFile(path, []byte(unit), 0o644); err != nil {
		return err
	}
	if out, err := exec.Command("systemctl", "--user", "enable", "--now", unitName).CombinedOutput(); err != nil {
		return fmt.Errorf("systemctl --user enable --now %s: %v %s", unitName, err, strings.TrimSpace(string(out)))
	}
	fmt.Println("installed " + path)
	return nil
}

func removeAutostart() error {
	_ = exec.Command("systemctl", "--user", "disable", "--now", unitName).Run()
	path, err := unitPath()
	if err != nil {
		return err
	}
	if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
		return err
	}
	return nil
}

func notify(message string) { fmt.Println(message) }

// keptOut is for Windows, where a folder's attributes tell what its name does not. The folders looked into here
// are named one by one (platformRoots), not searched for.
func keptOut(os.DirEntry) bool { return false }

// lockInstance takes this user's lock (a file in the config folder, so two users of one machine do not meet).
// running is true when another copy of this user holds it; any other failure is reported and does not stop the program.
func lockInstance(dir string) (release func(), running bool, err error) {
	f, err := os.OpenFile(filepath.Join(dir, "lock"), os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return func() {}, false, err
	}
	if err := syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return func() {}, errors.Is(err, syscall.EWOULDBLOCK), err
	}
	return func() { f.Close() }, false, nil
}

// settle makes this process the one copy that runs for this user. With renewed, the start brought a setting
// (--url, --wow-dir), which the caller takes once settle has said yes: a copy that already runs keeps it out, and
// the person is told to stop that copy first.
func settle(dir string, st *state, renewed bool) (release func(), proceed bool) {
	release, running, err := lockInstance(dir)
	if running {
		if renewed { // nothing asks the copy that runs to leave: the settings given wait for it to be stopped
			notify(text("notrenewedunit"))
		} else {
			notify(text("running") + "\n\n" + describe(st))
		}
		return nil, false
	}
	if err != nil {
		log.Printf("no instance lock: %v", err)
	}
	return release, true
}

func french() bool {
	for _, name := range []string{"LC_ALL", "LC_MESSAGES", "LANG"} {
		if v := os.Getenv(name); v != "" {
			return strings.HasPrefix(v, "fr")
		}
	}
	return false
}

// setupLog leaves the log where it goes by itself, the journal of the systemd unit: there is no file to name.
func setupLog(string) string { return "" }

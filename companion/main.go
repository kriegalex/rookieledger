// rookieledger-sync uploads the RookieLedger addon's saved file to the RookieLedger site whenever the game has rewritten it
// (at logout or /reload). It needs no settings: it finds the WoW Forever folder, reads the upload token the addon
// stored in the file, and sends the file with it. The site accepts a token only once its owner has registered it;
// until then this program asks "is my token known?" at most every 30 minutes and sends nothing else.
//
//	rookieledger-sync             watch and upload (on Windows every start also installs it, see platform_windows.go)
//	rookieledger-sync --install   start with the session (systemd user unit / Windows Run key), then watch
//	rookieledger-sync --uninstall remove the autostart
//	rookieledger-sync --status    print the files found and their tokens, then exit
//	rookieledger-sync --once      one pass, then exit
//	  --wow-dir DIR   the "World of Warcraft" folder, when it is not found by itself (remembered)
//	  --url URL       the upload address (remembered; "default" goes back to the RookieLedger site)
//	  --background    Windows: start without opening the window (how the session starts it)
//
// On Windows the menu of its icon holds two settings: whether it starts with the session (it does unless switched
// off) and whether its window also says why the site or the game's data is not found.
package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"time"
)

const (
	defaultURL      = "https://rookieledger-api.21crypto.ch/v1/ledger"
	flavor          = "_forever_"
	savedFile       = "RookieLedger.lua"
	pollEvery       = 60 * time.Second
	recheckEvery    = 30 * time.Minute // how often an unregistered token asks again
	rediscoverEvery = 30 * time.Minute // how often the disks are searched again for a WoW folder once one is known
	probeEvery      = 10 * time.Minute // how often the window asks whether the site is up, when nothing else was sent
	settleFor       = 5 * time.Second  // a file changed this recently may still be being written
	maxFileBytes    = 8 << 20
	maxLogBytes     = 1 << 20
)

// version is the release tag, set by the build (-ldflags "-X main.version=v1.2.3").
var version = "dev"

var tokenRE = regexp.MustCompile(`\["token"\] = "([0-9a-f]{32})"`)

type fileState struct {
	SHA  string `json:"sha"`            // the content last accepted, or last refused
	Note string `json:"note,omitempty"` // why the site refused it, shown by --status
}

type state struct {
	WowDirs   []string             `json:"wow_dirs,omitempty"`
	URL       string               `json:"url,omitempty"` // the upload address when it is not the built-in one
	Files     map[string]fileState `json:"files,omitempty"`
	Installed bool                 `json:"installed,omitempty"`
	LastSync  time.Time            `json:"last_sync,omitzero"` // when the site last accepted a file
	// The two settings of the Windows window's menu. Each is written as what the person switched away from the
	// default, so that a state file of before them, or without them, means the default.
	NoAutostart bool `json:"no_autostart,omitempty"` // do not start with the session
	Debug       bool `json:"debug,omitempty"`        // the window also says why something is wrong

	mu sync.Mutex // the window changes the settings while the watching loop notes what it uploaded
}

// change makes a change to the state that the window or the watching loop may be reading.
func (st *state) change(f func()) {
	st.mu.Lock()
	defer st.mu.Unlock()
	f()
}

func (st *state) autostart() bool {
	st.mu.Lock()
	defer st.mu.Unlock()
	return !st.NoAutostart
}

func (st *state) debug() bool {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.Debug
}

// uploadURL is where this installation uploads: the address given once with --url, else the RookieLedger site.
func (st *state) uploadURL() string {
	if st.URL != "" {
		return st.URL
	}
	return defaultURL
}

// setURL remembers the address given with --url; "default" goes back to the built-in one.
func (st *state) setURL(given string) {
	given = strings.TrimRight(strings.TrimSpace(given), "/")
	if given == "default" {
		given = ""
	}
	st.URL = given
}

type tokenStatus struct {
	registered bool
	checked    time.Time
}

// view is what the Windows window shows. The watching loop writes it, the window reads a copy.
type view struct {
	LastSync time.Time // when the site last accepted a file
	Checked  time.Time // when the site last answered, or failed to
	Up       bool      // what that answer was
	Files    int       // saved files found; -1 before the first look
	Problem  string    // why the site did not answer the last time it was asked; empty when it did
	Waiting  bool      // the site does not accept a token yet
	Game     string    // what was found of the game on this computer, a line per thing (see gameDetails)
}

type syncer struct {
	url    string
	client *http.Client
	st     *state
	save   func()
	tokens map[string]*tokenStatus
	now    func() time.Time

	logPath    string        // where the log is written, for the window to say; empty when there is none
	probeEvery time.Duration // how often to ask whether the site is up when nothing else was sent; 0: never
	changed    func()        // told when the view changes; may be nil
	logged     string        // the details last written to the log
	mu         sync.Mutex    // guards shown
	shown      view
}

func (s *syncer) view() view {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.shown
}

func (s *syncer) show(change func(*view)) {
	s.mu.Lock()
	before := s.shown
	change(&s.shown)
	same := before == s.shown
	s.mu.Unlock()
	if !same && s.changed != nil {
		s.changed()
	}
}

func configDir() string {
	dir, err := os.UserConfigDir()
	if err != nil {
		dir = "."
	}
	return filepath.Join(dir, "RookieLedgerSync")
}

func loadState(path string) *state {
	st := &state{}
	if data, err := os.ReadFile(path); err == nil {
		_ = json.Unmarshal(data, st)
	}
	if st.Files == nil {
		st.Files = map[string]fileState{}
	}
	return st
}

func saveState(path string, st *state) {
	st.mu.Lock() // also one writer of the file at a time
	defer st.mu.Unlock()
	data, _ := json.MarshalIndent(st, "", "  ")
	tmp := path + ".tmp"
	if os.WriteFile(tmp, data, 0o600) == nil {
		_ = os.Rename(tmp, path)
	}
}

// findSavedFiles lists the addon's saved file of every WoW account under the given "World of Warcraft" folders.
// The folders are read as they are named, never as patterns: "Games [SSD]" is a folder, not a character class.
func findSavedFiles(roots []string) []string {
	seen := map[string]bool{}
	var out []string
	for _, root := range roots {
		accounts := filepath.Join(root, flavor, "WTF", "Account")
		entries, _ := os.ReadDir(accounts)
		for _, entry := range entries {
			m := filepath.Join(accounts, entry.Name(), "SavedVariables", savedFile)
			if real, err := filepath.EvalSymlinks(m); err == nil && !seen[real] {
				seen[real] = true
				out = append(out, m)
			}
		}
	}
	sort.Strings(out)
	return out
}

func holdsForever(dir string) bool {
	info, err := os.Stat(filepath.Join(dir, flavor))
	return err == nil && info.IsDir()
}

// expandRoots turns candidates into existing folders that hold a WoW Forever install. A candidate is first taken
// as the folder it names (the one given with --wow-dir, the one in the registry), then as a pattern.
func expandRoots(candidates []string) []string {
	var out []string
	for _, c := range candidates {
		if holdsForever(c) {
			out = append(out, c)
			continue
		}
		matches, _ := filepath.Glob(c)
		for _, m := range matches {
			if holdsForever(m) {
				out = append(out, m)
			}
		}
	}
	return out
}

// accounts counts the WoW accounts that logged in from an install, and those among them that hold the addon's
// saved file.
func accounts(root string) (all, withData int) {
	dir := filepath.Join(root, flavor, "WTF", "Account")
	entries, _ := os.ReadDir(dir)
	for _, entry := range entries {
		if !entry.IsDir() || entry.Name() == "SavedVariables" {
			continue
		}
		all++
		if _, err := os.Stat(filepath.Join(dir, entry.Name(), "SavedVariables", savedFile)); err == nil {
			withData++
		}
	}
	return all, withData
}

// otherFlavors names the game versions a "World of Warcraft" folder holds ("_retail_, _classic_").
func otherFlavors(dir string) string {
	var names []string
	entries, _ := os.ReadDir(dir)
	for _, entry := range entries {
		if name := entry.Name(); entry.IsDir() && len(name) > 2 && strings.HasPrefix(name, "_") && strings.HasSuffix(name, "_") {
			names = append(names, name)
		}
	}
	return strings.Join(names, ", ")
}

// gameDetails says what was found of the game, a line per thing, for who wonders why no data is found: each
// install with its accounts and whether the addon is there, or, when no install was found, the folders among the
// candidates (the places looked in, as names or patterns) that exist without holding WoW Forever, and a folder
// given with --wow-dir that does not exist.
func gameDetails(found, candidates, given []string) string {
	var lines []string
	for _, root := range found {
		all, withData := accounts(root)
		line := fmt.Sprintf(text("dfolder"), root, all, withData)
		if withData == 0 {
			_, err := os.Stat(filepath.Join(root, flavor, "Interface", "AddOns", "RookieLedger"))
			switch {
			case err != nil:
				line += text("dnoaddon")
			case all == 0:
				line += text("dnologin")
			default:
				line += text("dnologout")
			}
		}
		lines = append(lines, line)
	}
	if len(found) == 0 {
		lines = append(lines, text("dnofolder"))
		seen := map[string]bool{}
		for _, c := range candidates {
			matches, _ := filepath.Glob(c)
			for _, dir := range append([]string{c}, matches...) {
				key := strings.ToLower(filepath.Clean(dir))
				info, err := os.Stat(dir)
				// A folder named like a game version is one inside an install, which is listed by itself.
				if seen[key] || err != nil || !info.IsDir() || strings.HasPrefix(filepath.Base(dir), "_") || len(seen) >= 3 {
					continue
				}
				seen[key] = true
				if flavors := otherFlavors(dir); flavors != "" {
					lines = append(lines, fmt.Sprintf(text("dotherflavor"), dir, flavors))
				} else {
					lines = append(lines, fmt.Sprintf(text("dnotwow"), dir))
				}
			}
		}
	}
	for _, dir := range given {
		if _, err := os.Stat(dir); err != nil {
			lines = append(lines, fmt.Sprintf(text("dnogiven"), dir))
		}
	}
	return strings.Join(lines, "\n")
}

// explain says why the site could not be asked, in words a member can act on, followed by the error as it came:
// that is what they paste when asking for help.
func explain(err error) string {
	var dns *net.DNSError
	var cert *tls.CertificateVerificationError
	var timeout interface{ Timeout() bool }
	why := "noconnect"
	switch {
	case errors.As(err, &dns):
		why = "nodns"
	case errors.As(err, &cert):
		why = "nocert"
	case errors.As(err, &timeout) && timeout.Timeout():
		why = "timeout"
	}
	raw := err.Error()
	if len(raw) > 200 {
		raw = raw[:200] + "…"
	}
	return text(why) + " (" + raw + ")"
}

// details is what the window shows below its three lines when the debug setting is on: where it uploads to and
// why that failed, whether a token waits, what was found of the game, and where the log is.
func (s *syncer) details() string {
	v := s.view()
	lines := []string{text("daddress") + s.url}
	if v.Problem != "" {
		lines = append(lines, v.Problem)
	}
	if v.Waiting {
		lines = append(lines, text("dwaiting"))
	}
	if v.Game != "" {
		lines = append(lines, v.Game)
	}
	if s.logPath != "" {
		lines = append(lines, text("dlog")+s.logPath)
	}
	return strings.Join(lines, "\n")
}

func readToken(data []byte) string {
	if m := tokenRE.FindSubmatch(data); m != nil {
		return string(m[1])
	}
	return ""
}

func (s *syncer) request(method, path, token string, body []byte) (int, string, error) {
	var reader io.Reader
	if body != nil {
		var buf bytes.Buffer
		zw := gzip.NewWriter(&buf)
		_, _ = zw.Write(body)
		_ = zw.Close()
		reader = &buf
	}
	req, err := http.NewRequest(method, s.url+"/"+path, reader)
	if err != nil {
		return 0, "", err
	}
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	req.Header.Set("User-Agent", "RookieLedgerSync/"+version)
	if body != nil {
		req.Header.Set("Content-Encoding", "gzip")
	}
	resp, err := s.client.Do(req)
	// A gateway's 502 or 503 is an answer, but not the site's: it is down behind its front door.
	problem := ""
	if err != nil {
		problem = explain(err)
	} else if resp.StatusCode >= 500 {
		problem = fmt.Sprintf(text("sitedown"), resp.StatusCode)
	}
	s.show(func(v *view) { v.Checked, v.Up, v.Problem = s.now(), problem == "", problem })
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	text, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	return resp.StatusCode, strings.TrimSpace(string(text)), nil
}

// registered tells whether the site knows the token, asking it at most every recheckEvery while the answer is no.
func (s *syncer) registered(token string) bool {
	ts := s.tokens[token]
	if ts == nil {
		ts = &tokenStatus{}
		s.tokens[token] = ts
	}
	if ts.registered {
		return true
	}
	if !ts.checked.IsZero() && s.now().Sub(ts.checked) < recheckEvery {
		return false
	}
	code, _, err := s.request("GET", "status", token, nil)
	if err != nil {
		// No answer is not a "no": ask again on the next pass, as a failed upload is sent again. A program started
		// with the session often runs before the network is up.
		log.Printf("site not reachable, will retry: %v", err)
		return false
	}
	ts.checked = s.now()
	s.show(func(v *view) { v.Waiting = code == http.StatusUnauthorized })
	switch {
	case code == http.StatusNoContent:
		ts.registered = true
		log.Printf("token %s… is registered", token[:6])
	case code == http.StatusUnauthorized:
		// Never the whole token: this log is what a member pastes when asking why nothing uploads.
		log.Printf("token %s… not accepted yet: if the site registers tokens by hand, /ledger token in game shows it, to give to that site's keeper", token[:6])
	default:
		log.Printf("unexpected answer %d to the status check", code)
	}
	return ts.registered
}

// syncFile uploads one saved file if its content is new and its token is registered.
func (s *syncer) syncFile(path string) {
	info, err := os.Stat(path)
	if err != nil || info.Size() == 0 || info.Size() > maxFileBytes || s.now().Sub(info.ModTime()) < settleFor {
		return
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return
	}
	token := readToken(data)
	if token == "" {
		return
	}
	sum := sha256.Sum256(data)
	sha := hex.EncodeToString(sum[:])
	if s.st.Files[path].SHA == sha || !s.registered(token) {
		return
	}
	code, text, err := s.request("POST", "upload", token, data)
	switch {
	case err != nil:
		log.Printf("upload failed, will retry: %v", err)
	case code == http.StatusOK:
		log.Printf("uploaded %s: %s", filepath.Base(filepath.Dir(filepath.Dir(path))), text)
		s.st.change(func() {
			s.st.Files[path] = fileState{SHA: sha}
			s.st.LastSync = s.now()
		})
		s.save()
		s.show(func(v *view) { v.LastSync = s.st.LastSync })
	case code == http.StatusUnauthorized:
		s.tokens[token] = &tokenStatus{checked: s.now()}
		s.show(func(v *view) { v.Waiting = true })
		log.Printf("token no longer accepted; asking again in %s", recheckEvery)
	case code >= 400 && code < 500 && code != http.StatusRequestTimeout && code != http.StatusTooManyRequests:
		// The site will not take this content (unreadable, too large, a record id that is not this token's): sending
		// it again would not help. A new save of the game is tried again, and --status says why this one was refused.
		log.Printf("the site refused the file (%d %s); waiting for the game to write a new one", code, text)
		s.st.change(func() { s.st.Files[path] = fileState{SHA: sha, Note: fmt.Sprintf("%d %s", code, text)} })
		s.save()
	default:
		log.Printf("upload answered %d, will retry", code)
	}
}

func (s *syncer) pass(roots []string) int {
	files := findSavedFiles(roots)
	for _, f := range files {
		s.syncFile(f)
	}
	var candidates []string
	if len(roots) == 0 { // looked for again on every pass while nothing is found (rootFinder), so this costs no more
		candidates = append(append([]string{}, s.st.WowDirs...), platformRoots()...)
	}
	game := gameDetails(roots, candidates, s.st.WowDirs)
	s.show(func(v *view) { v.Files, v.Game = len(files), game })
	s.probe()
	if detail := s.details(); detail != s.logged && s.st.debug() {
		s.logged = detail // with the debug setting, the log holds what the window shows, for who is asked to send it
		log.Printf("details:\n%s", detail)
	}
	return len(files)
}

// probe asks the site whether it is up, for the window, when nothing was sent for probeEvery. It sends no token:
// the site answers 401, which is answer enough.
func (s *syncer) probe() {
	if s.probeEvery == 0 {
		return
	}
	if v := s.view(); !v.Checked.IsZero() && s.now().Sub(v.Checked) < s.probeEvery {
		return
	}
	_, _, _ = s.request("GET", "status", "", nil)
}

func roots(st *state) []string {
	return expandRoots(append(append([]string{}, st.WowDirs...), platformRoots()...))
}

// rootFinder remembers where WoW was found. Looking for it costs two registry queries and a look at every drive on
// Windows, a walk three folders deep under /mnt and /media on Linux: not something to repeat every minute for weeks.
// While nothing is found it looks on every pass, so a game installed later is still picked up.
type rootFinder struct {
	find   func() []string
	now    func() time.Time
	dirs   []string
	looked time.Time
}

func (r *rootFinder) roots() []string {
	if len(r.dirs) == 0 || r.now().Sub(r.looked) >= rediscoverEvery {
		r.dirs, r.looked = r.find(), r.now()
	}
	return r.dirs
}

// describe lists what was found, for --status and the Windows message box.
func describe(st *state) string {
	var b strings.Builder
	files := findSavedFiles(roots(st))
	if len(files) == 0 {
		b.WriteString(text("nofile"))
		found := roots(st)
		var candidates []string
		if len(found) == 0 {
			candidates = append(append([]string{}, st.WowDirs...), platformRoots()...)
		}
		b.WriteString(gameDetails(found, candidates, st.WowDirs) + "\n")
		return b.String()
	}
	for _, f := range files {
		data, _ := os.ReadFile(f)
		token := readToken(data)
		if token == "" {
			token = "?"
		}
		fmt.Fprintf(&b, text("found"), filepath.Base(filepath.Dir(filepath.Dir(f))), token)
		if note := st.Files[f].Note; note != "" {
			fmt.Fprintf(&b, text("refused"), note)
		}
	}
	b.WriteString(text("give"))
	return b.String()
}

func main() {
	wowDir := flag.String("wow-dir", "", `the "World of Warcraft" folder`)
	url := flag.String("url", "", `upload address, remembered ("default": the RookieLedger site)`)
	once := flag.Bool("once", false, "one pass, then exit")
	install := flag.Bool("install", false, "start with the session, then watch")
	uninstall := flag.Bool("uninstall", false, "remove the autostart")
	status := flag.Bool("status", false, "print the files found and their tokens")
	background := flag.Bool("background", false, "Windows: start without opening the window")
	flag.Parse()

	dir := configDir()
	_ = os.MkdirAll(dir, 0o700)
	statePath := filepath.Join(dir, "state.json")
	st := loadState(statePath)
	if *wowDir != "" {
		abs, _ := filepath.Abs(*wowDir)
		st.WowDirs = []string{abs}
		saveState(statePath, st)
	}
	if *url != "" {
		st.setURL(*url)
		saveState(statePath, st)
	}
	if *status {
		// Through notify: the Windows program has no console to print to.
		notify(strings.TrimRight(describe(st), "\n"))
		return
	}
	if *uninstall {
		if err := removeAutostart(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		st.Installed = false
		saveState(statePath, st)
		return
	}
	if *install && !st.autostart() {
		st.NoAutostart = false // asked for by name: the setting follows
		saveState(statePath, st)
	}
	if *install && installHandsOver {
		// The session manager runs the program from now on; this process only installs it.
		if err := installAutostart(); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		st.Installed = true
		saveState(statePath, st)
		fmt.Print(describe(st))
		return
	}
	logPath := setupLog(filepath.Join(dir, "sync.log"))

	if !*once {
		// One copy per user: settle makes this process that copy, or says that another one is.
		release, proceed := settle(dir, st, *wowDir != "" || *url != "")
		if !proceed {
			return
		}
		defer release()
	}

	s := &syncer{url: st.uploadURL(), client: &http.Client{Timeout: 30 * time.Second}, st: st,
		save: func() { saveState(statePath, st) }, tokens: map[string]*tokenStatus{}, now: time.Now,
		shown: view{LastSync: st.LastSync, Files: -1}, logPath: logPath}
	log.Printf("rookieledger-sync %s, uploading to %s", version, s.url)
	finder := &rootFinder{find: func() []string { return roots(st) }, now: time.Now}
	if *once {
		log.Printf("%d saved file(s) found", s.pass(finder.roots()))
		return
	}
	// serve runs watch for as long as the program does; on Windows it also shows the tray icon and the window.
	serve(s, !*background, func() {
		found := -1
		for {
			n := s.pass(finder.roots())
			if n != found {
				log.Printf("%d saved file(s) found", n)
				found = n
			}
			time.Sleep(pollEvery)
		}
	})
}

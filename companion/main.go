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
package main

import (
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
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
}

type syncer struct {
	url    string
	client *http.Client
	st     *state
	save   func()
	tokens map[string]*tokenStatus
	now    func() time.Time

	probeEvery time.Duration // how often to ask whether the site is up when nothing else was sent; 0: never
	changed    func()        // told when the view changes; may be nil
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
	s.show(func(v *view) { v.Checked, v.Up = s.now(), err == nil && resp.StatusCode < 500 })
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
		s.st.Files[path] = fileState{SHA: sha}
		s.st.LastSync = s.now()
		s.save()
		s.show(func(v *view) { v.LastSync = s.st.LastSync })
	case code == http.StatusUnauthorized:
		s.tokens[token] = &tokenStatus{checked: s.now()}
		log.Printf("token no longer accepted; asking again in %s", recheckEvery)
	case code >= 400 && code < 500 && code != http.StatusRequestTimeout && code != http.StatusTooManyRequests:
		// The site will not take this content (unreadable, too large, a record id that is not this token's): sending
		// it again would not help. A new save of the game is tried again, and --status says why this one was refused.
		log.Printf("the site refused the file (%d %s); waiting for the game to write a new one", code, text)
		s.st.Files[path] = fileState{SHA: sha, Note: fmt.Sprintf("%d %s", code, text)}
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
	s.show(func(v *view) { v.Files = len(files) })
	s.probe()
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
	setupLog(filepath.Join(dir, "sync.log"))

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
		shown: view{LastSync: st.LastSync, Files: -1}}
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

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
//	  --wow-dir DIR   the "World of Warcraft" folder, when it is not found by itself (remembered; on Windows the
//	                  window's button asks for it)
//	  --url URL       the upload address (remembered; "default" goes back to the RookieLedger site; on Windows the
//	                  window's advanced settings hold it too). Read as the window reads it: see siteAddress
//	  --background    Windows: start without opening the window (how the session starts it)
//
// On Windows the window holds the settings: whether the program starts with the session (it does unless switched
// off), and, among the advanced ones, the upload address and whether the window also says why the site or the
// game's data is not found.
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
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

const (
	defaultURL      = "https://rookieledger-api.21crypto.ch/v1/ledger"
	flavor          = "_forever_"
	savedFile       = "RookieLedger.lua"
	pollEvery       = time.Minute      // how often the saved files are looked at unless the person chose otherwise
	retryEvery      = time.Minute      // how soon the next pass comes while the site does not answer
	recheckEvery    = 30 * time.Minute // how often an unregistered token asks again
	rediscoverEvery = 30 * time.Minute // how often the disks are searched again for a WoW folder, found or not
	probeEvery      = 10 * time.Minute // the least wait before the window asks whether the site is up, nothing else sent
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
	// Two settings of the Windows window. Each is written as what the person switched away from the
	// default, so that a state file of before them, or without them, means the default.
	NoAutostart bool `json:"no_autostart,omitempty"` // do not start with the session
	Debug       bool `json:"debug,omitempty"`        // the window also says why something is wrong

	// Where the game was last found by a search. A disk that is not ready when the session starts (plugged in, or
	// unlocked, a moment later) makes that first search find nothing: these folders are then looked at again on
	// every pass, which costs nothing, where a new search is half an hour away.
	KnownDirs []string `json:"known_dirs,omitempty"`
	// How often the saved files are looked at, in minutes: one of pollChoices, chosen in the Windows window. Zero, or
	// anything else, is the default.
	PollMinutes int `json:"poll_minutes,omitempty"`

	mu sync.Mutex // the window changes the settings while the watching loop notes what it uploaded
}

// knownDirs is where the game was pointed to or last found: the places worth a look without a search.
func (st *state) knownDirs() []string {
	st.mu.Lock()
	defer st.mu.Unlock()
	return append(append([]string{}, st.WowDirs...), st.KnownDirs...)
}

// remember notes where a search found the game, and tells whether that is news. A search that found nothing
// changes nothing: the disk may only be away.
func (st *state) remember(found []string) bool {
	st.mu.Lock()
	defer st.mu.Unlock()
	if len(found) == 0 || strings.Join(found, "\n") == strings.Join(st.KnownDirs, "\n") {
		return false
	}
	st.KnownDirs = append([]string{}, found...)
	return true
}

// pollChoices are the waits between two looks at the saved files that the window offers, in minutes.
var pollChoices = []int{1, 5, 10}

// pollMinutes is the wait chosen, the default when none was.
func (st *state) pollMinutes() int {
	st.mu.Lock()
	defer st.mu.Unlock()
	for _, choice := range pollChoices {
		if st.PollMinutes == choice {
			return choice
		}
	}
	return int(pollEvery / time.Minute)
}

// pollLabel says a wait as the window lists it: "every minute", "every 5 minutes".
func pollLabel(minutes int) string {
	if minutes == 1 {
		return text("everyminute")
	}
	return fmt.Sprintf(text("everyminutes"), minutes)
}

// change makes a change to the state that the window or the watching loop may be reading.
func (st *state) change(f func()) {
	st.mu.Lock()
	defer st.mu.Unlock()
	f()
}

// wowDirs is the folder the person pointed to as their "World of Warcraft" folder, if they did.
func (st *state) wowDirs() []string {
	st.mu.Lock()
	defer st.mu.Unlock()
	return append([]string{}, st.WowDirs...)
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

// uploadURL is where this installation uploads: the address given with --url or in the window, else the
// RookieLedger site.
func (st *state) uploadURL() string {
	st.mu.Lock()
	defer st.mu.Unlock()
	if st.URL != "" {
		return st.URL
	}
	return defaultURL
}

// customURL is the address given, empty for the RookieLedger site: what the window's field shows.
func (st *state) customURL() string {
	st.mu.Lock()
	defer st.mu.Unlock()
	return st.URL
}

// setURL remembers the address given with --url or in the window; "default", or the RookieLedger site's own address,
// goes back to the built-in one. Another site has none of the files yet: they are all sent to it, and nothing was
// sent to it yet. It tells whether the address changed.
func (st *state) setURL(given string) bool {
	given = strings.TrimRight(strings.TrimSpace(given), "/")
	if given == "default" || given == defaultURL {
		given = ""
	}
	st.mu.Lock()
	defer st.mu.Unlock()
	if given == st.URL {
		return false
	}
	st.URL, st.Files, st.LastSync = given, map[string]fileState{}, time.Time{}
	return true
}

// errNotSite is the answer to an address, typed in the window or given with --url, that siteAddress does not take.
var errNotSite = errors.New("not a site's address")

// siteAddress reads an address typed in the window's field or given with --url. Empty is the RookieLedger site, given
// back as "", as is that site's own address. A name without a scheme is taken as https, and an address without a path
// is given the upload path, so that "example.org" is enough. Only https is taken, since the token goes with every
// request; plain http only for a site on this computer, which a network never sees.
func siteAddress(typed string) (string, error) {
	typed = strings.TrimSpace(typed)
	if typed == "" || typed == "default" {
		return "", nil
	}
	if !strings.Contains(typed, "://") {
		typed = "https://" + typed
	}
	u, err := url.Parse(typed)
	if err != nil || u.Scheme != "https" && (u.Scheme != "http" || !onThisComputer(u.Hostname())) || u.Hostname() == "" ||
		u.User != nil || u.RawQuery != "" || u.Fragment != "" || strings.ContainsAny(u.Host, " \t") {
		return "", errNotSite
	}
	// A name is the same in capitals: the RookieLedger site typed so is still that site.
	u.Host, u.Path, u.RawPath = strings.ToLower(u.Host), strings.TrimRight(u.Path, "/"), ""
	if u.Path == "" {
		u.Path = "/v1/ledger"
	}
	if address := u.String(); address != defaultURL {
		return address, nil
	}
	return "", nil
}

// onThisComputer tells whether a host name is this computer's own (localhost, 127.0.0.1, ::1): what is sent to it
// never crosses a network.
func onThisComputer(host string) bool {
	if strings.EqualFold(host, "localhost") {
		return true
	}
	ip := net.ParseIP(host)
	return ip != nil && ip.IsLoopback()
}

// checkRedirect follows a site's redirects by siteAddress's rule: the token goes along, so never to plain http away
// from this computer.
func checkRedirect(req *http.Request, via []*http.Request) error {
	if len(via) >= 10 {
		return errors.New("stopped after 10 redirects")
	}
	if req.URL.Scheme != "https" && !onThisComputer(req.URL.Hostname()) {
		return errors.New("redirected to " + req.URL.Scheme + " away from this computer")
	}
	return nil
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
	Wrong    bool      // the address answers, but not as a RookieLedger site: mistyped, or another server's
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
	wake       chan struct{} // asks the watching loop to look again now; may be nil
	search     atomic.Bool   // and to search the disks for the game first
	logged     string        // the details last written to the log
	candidates []string      // where the game could be, as last searched for while it is not found
	searched   time.Time     // when that was; zero: to be searched for again
	mu         sync.Mutex    // guards shown and next
	shown      view
	next       *string // the address the window gave, for the watching loop to take before its next pass
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

// look asks the watching loop for a pass now: the person changed how often it looks, or (search) pointed to the
// game's folder, and the disks are then searched anew first.
func (s *syncer) look(search bool) {
	if search {
		s.search.Store(true)
	}
	select {
	case s.wake <- struct{}{}:
	default: // already asked, or nobody watches
	}
}

// point has the watching loop upload to another address, given in the window ("" for the RookieLedger site), from
// a pass that comes at once.
func (s *syncer) point(address string) {
	s.mu.Lock()
	s.next = &address
	s.mu.Unlock()
	s.look(false)
}

// pointing tells whether an address the window gave waits for the watching loop to take it: until then, what the
// view says of the site is the old address's answer.
func (s *syncer) pointing() bool {
	s.mu.Lock()
	defer s.mu.Unlock()
	return s.next != nil
}

// follow takes the address the window gave, between two passes, so that no upload to the old one is under way: the
// new site is asked about each token anew and sent every file.
func (s *syncer) follow() {
	s.mu.Lock()
	next := s.next
	s.next = nil
	s.mu.Unlock()
	if next == nil {
		return
	}
	if !s.st.setURL(*next) {
		// The address in use again: the window, which said it was checking, shows the last answer once more.
		if s.changed != nil {
			s.changed()
		}
		return
	}
	s.url, s.tokens = s.st.uploadURL(), map[string]*tokenStatus{}
	s.save()
	s.show(func(v *view) {
		v.LastSync, v.Checked, v.Up, v.Problem, v.Wrong, v.Waiting = time.Time{}, time.Time{}, false, "", false, false
	})
	log.Printf("uploading to %s from now on", s.url)
}

// wait is how long the watching loop sleeps before its next pass: what the person chose, and no longer than
// retryEvery while the site does not answer. A program started with the session often runs before the network is
// up: what it could not send then is not left for ten minutes.
func (s *syncer) wait() time.Duration {
	wait := time.Duration(s.st.pollMinutes()) * time.Minute
	if s.view().Problem != "" && wait > retryEvery {
		wait = retryEvery
	}
	return wait
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

const wowFolder = "World of Warcraft"

// skipFolder tells the folders that are not looked into for an install, by their names: those of Windows itself,
// those that hold programs' own data, the folders a cloud service keeps in step with its servers (listing one can
// make it fetch what is not on the disk), hidden ones, and an install itself. On Windows, keptOut adds what a
// folder's attributes say, whatever its name.
func skipFolder(name string) bool {
	lower := strings.ToLower(name)
	switch lower {
	case "windows", "windows.old", "system volume information", "recovery", "perflogs", "programdata", "appdata",
		"msocache", "config.msi", "documents and settings", "dropbox", "google drive", "iclouddrive",
		strings.ToLower(wowFolder):
		return true
	}
	// "OneDrive", and "OneDrive - Some Company" for a work account.
	return strings.HasPrefix(lower, "onedrive") || strings.HasPrefix(name, "$") || strings.HasPrefix(name, ".")
}

// installsBelow lists the "World of Warcraft" folders that sit in top or up to depth folders further down: the
// game is wherever its player put it (F:\Battlenet\World of Warcraft), which no list of usual names covers. Links
// to other folders are not followed.
func installsBelow(top string, depth int) []string {
	var out []string
	wow := filepath.Join(top, wowFolder)
	if info, err := os.Stat(wow); err == nil && info.IsDir() {
		out = append(out, wow)
	}
	if depth <= 0 {
		return out
	}
	entries, _ := os.ReadDir(top)
	for _, entry := range entries {
		if entry.IsDir() && !skipFolder(entry.Name()) && !keptOut(entry) {
			out = append(out, installsBelow(filepath.Join(top, entry.Name()), depth-1)...)
		}
	}
	return out
}

// installFrom is the "World of Warcraft" folder meant by who picked a folder in a dialog: the folder itself, one
// it is inside of (they went into _forever_, or down to an account), or one just below it (they stopped at the
// folder WoW is in). False when no WoW Forever is around it.
func installFrom(picked string) (string, bool) {
	dir := filepath.Clean(picked)
	for range 6 { // an account's SavedVariables is five folders down an install
		if holdsForever(dir) {
			return dir, true
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			break
		}
		dir = parent
	}
	for _, wow := range installsBelow(picked, 2) {
		if holdsForever(wow) {
			return wow, true
		}
	}
	return "", false
}

func holdsForever(dir string) bool {
	info, err := os.Stat(filepath.Join(dir, flavor))
	return err == nil && info.IsDir()
}

// expandRoots turns candidates into existing folders that hold a WoW Forever install. A candidate is first taken
// as the folder it names (the one given with --wow-dir, the one in the registry), then as a pattern.
//
// An install is listed once, however many candidates lead to it: the folder the person pointed to, the one in the
// registry and the one found on the disk are often the same.
func expandRoots(candidates []string) []string {
	var out []string
	var seen []os.FileInfo
	add := func(dir string) {
		info, err := os.Stat(dir)
		if err != nil {
			return
		}
		for _, have := range seen {
			if os.SameFile(have, info) {
				return
			}
		}
		seen, out = append(seen, info), append(out, dir)
	}
	for _, c := range candidates {
		if holdsForever(c) {
			add(c)
			continue
		}
		matches, _ := filepath.Glob(c)
		for _, m := range matches {
			if holdsForever(m) {
				add(m)
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
// given with --wow-dir or the window's button that does not exist.
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
		lines = append(lines, text(noFolderText))
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

// details is what the window shows below its advanced settings when the debug setting is on: why the site was not
// reached, whether a token waits, and what was found of the game. The address and the log's place are settings of
// their own there; the log says the address when the program starts and when it changes.
func (s *syncer) details() string {
	v := s.view()
	var lines []string
	if v.Problem != "" {
		lines = append(lines, v.Problem)
	}
	if v.Waiting {
		lines = append(lines, text("dwaiting"))
	}
	if v.Game != "" {
		lines = append(lines, v.Game)
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
	// A gateway's 502 or 503 is an answer, but not the site's: it is down behind its front door. Any web server
	// answers too: what it says to the status question tells whether it is a RookieLedger site.
	problem, wrong := "", false
	switch {
	case err != nil:
		problem = explain(err)
	case resp.StatusCode >= 500:
		problem = fmt.Sprintf(text("sitedown"), resp.StatusCode)
	case path == "status" && !ledgerAnswer(resp.StatusCode):
		if s.url == defaultURL { // not the person's mistake: the RookieLedger site is down behind its front door
			problem = fmt.Sprintf(text("sitedown"), resp.StatusCode)
		} else {
			problem, wrong = fmt.Sprintf(text("notledger"), resp.StatusCode), true
		}
	}
	s.show(func(v *view) { v.Checked, v.Up, v.Problem, v.Wrong = s.now(), problem == "", problem, wrong })
	if err != nil {
		return 0, "", err
	}
	defer resp.Body.Close()
	text, _ := io.ReadAll(io.LimitReader(resp.Body, 4096))
	return resp.StatusCode, strings.TrimSpace(string(text)), nil
}

// ledgerAnswer tells whether an answer to the status question is one a RookieLedger site gives: the token is known
// (204), it is not or there is none (401), or the question came too often (429). Any other server answers otherwise,
// most often 404.
func ledgerAnswer(code int) bool {
	return code == http.StatusNoContent || code == http.StatusUnauthorized || code == http.StatusTooManyRequests
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
	s.follow()
	files := findSavedFiles(roots)
	for _, f := range files {
		s.syncFile(f)
	}
	var candidates []string
	if len(roots) == 0 {
		// The places that could hold the game are searched for as rarely as the game itself (rootFinder).
		if s.searched.IsZero() || s.now().Sub(s.searched) >= rediscoverEvery {
			s.candidates, s.searched = append(s.st.wowDirs(), platformRoots()...), s.now()
		}
		candidates = s.candidates
	}
	game := gameDetails(roots, candidates, s.st.wowDirs())
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
	return expandRoots(append(st.wowDirs(), platformRoots()...))
}

// rootFinder remembers where WoW was found, or that it was not. Looking for it costs two registry queries and a
// walk two folders deep on every drive on Windows, three folders deep under /mnt and /media on Linux: not
// something to repeat at every pass for weeks, least of all on a computer without the game. It is looked for when
// the program starts, when the person points to a folder, and every rediscoverEvery: a game installed later is
// picked up by then.
type rootFinder struct {
	find   func() []string
	quick  func() []string // the folders where the game was before, of those that hold it now; may be nil
	now    func() time.Time
	dirs   []string
	looked time.Time // zero: not looked for yet, or to be looked for again
}

// forget makes the next look a search: where WoW is has just changed.
func (r *rootFinder) forget() { r.looked = time.Time{} }

func (r *rootFinder) roots() []string {
	if r.looked.IsZero() || r.now().Sub(r.looked) >= rediscoverEvery {
		r.dirs, r.looked = r.find(), r.now()
	} else if len(r.dirs) == 0 && r.quick != nil {
		// Nothing found and no search due: the game may be on a disk that was not there yet when the session
		// started. Where it was before is looked at again, which is a few folders and no search.
		r.dirs = r.quick()
	}
	return r.dirs
}

// describe lists what was found, for --status and the Windows message box.
func describe(st *state) string {
	var b strings.Builder
	found := roots(st) // once: on Windows it is a search of every disk
	files := findSavedFiles(found)
	if len(files) == 0 {
		b.WriteString(text("nofile"))
		var candidates []string
		if len(found) == 0 {
			candidates = append(st.wowDirs(), platformRoots()...)
		}
		b.WriteString(gameDetails(found, candidates, st.wowDirs()) + "\n")
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
	url := flag.String("url", "", `upload address, remembered ("default": the RookieLedger site; "example.org" is enough)`)
	once := flag.Bool("once", false, "one pass, then exit")
	install := flag.Bool("install", false, "start with the session, then watch")
	uninstall := flag.Bool("uninstall", false, "remove the autostart")
	status := flag.Bool("status", false, "print the files found and their tokens")
	background := flag.Bool("background", false, "Windows: start without opening the window")
	flag.Parse()
	// Read as the window's field reads it, before anything else: refused, it must not make a running copy quit.
	address, err := siteAddress(*url)
	if err != nil {
		notify(fmt.Sprintf(text("badurl"), *url))
		os.Exit(2)
	}

	dir := configDir()
	_ = os.MkdirAll(dir, 0o700)
	statePath := filepath.Join(dir, "state.json")
	st := loadState(statePath)
	renewed := *wowDir != "" || *url != ""
	// take writes down the settings given (--wow-dir, --url). The program that goes on watching takes them once it is
	// the one copy that runs (settle): taken before, the copy that ran until then could write its state over them.
	take := func(st *state) {
		if *wowDir != "" {
			abs, _ := filepath.Abs(*wowDir)
			st.change(func() { st.WowDirs = []string{abs} })
		}
		if *url != "" {
			st.setURL(address) // "" for the RookieLedger site
		}
		if renewed {
			saveState(statePath, st)
		}
	}
	if *status || *uninstall || *once || *install && installHandsOver {
		take(st)
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
		release, proceed := settle(dir, st, renewed)
		if !proceed {
			return
		}
		defer release()
		if renewed { // what the copy that left wrote last, then the settings given
			st = loadState(statePath)
			take(st)
		}
	}

	// A redirection from https to plain http is not followed: the token goes with it, and the same host gets it.
	client := &http.Client{Timeout: 30 * time.Second, CheckRedirect: checkRedirect}
	s := &syncer{url: st.uploadURL(), client: client, st: st,
		save: func() { saveState(statePath, st) }, tokens: map[string]*tokenStatus{}, now: time.Now,
		shown: view{LastSync: st.LastSync, Files: -1}, logPath: logPath, wake: make(chan struct{}, 1)}
	log.Printf("rookieledger-sync %s, uploading to %s", version, s.url)
	finder := &rootFinder{now: time.Now,
		find: func() []string {
			found := roots(st)
			if st.remember(found) {
				saveState(statePath, st)
			}
			return found
		},
		quick: func() []string { return expandRoots(st.knownDirs()) }}
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
			select {
			case <-time.After(s.wait()):
			case <-s.wake:
				if s.search.Swap(false) {
					finder.forget()
					s.searched = time.Time{}
				}
			}
		}
	})
}

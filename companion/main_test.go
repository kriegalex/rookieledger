package main

import (
	"compress/gzip"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
	"time"
)

const testToken = "0123456789abcdef0123456789abcdef"

func writeSaved(t *testing.T, root, account, content string) string {
	t.Helper()
	dir := filepath.Join(root, flavor, "WTF", "Account", account, "SavedVariables")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, savedFile)
	if err := os.WriteFile(path, []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}
	old := time.Now().Add(-time.Minute) // not "still being written"
	_ = os.Chtimes(path, old, old)
	return path
}

func saved(extra string) string {
	return "\nRookieLedgerDB = {\n[\"token\"] = \"" + testToken + "\",\n[\"id\"] = \"0876cf1e\",\n" + extra + "}\n"
}

// site is a stand-in for the upload endpoint that counts what reaches it.
type site struct {
	registered       bool
	status, uploads  int
	lastBody, answer string
	code             int
}

func (s *site) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if r.Header.Get("Authorization") != "Bearer "+testToken || !s.registered {
		if strings.HasSuffix(r.URL.Path, "/status") {
			s.status++
		}
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	if strings.HasSuffix(r.URL.Path, "/status") {
		s.status++
		w.WriteHeader(http.StatusNoContent)
		return
	}
	s.uploads++
	zr, err := gzip.NewReader(r.Body)
	if err != nil {
		w.WriteHeader(http.StatusBadRequest)
		return
	}
	body, _ := io.ReadAll(zr)
	s.lastBody = string(body)
	if s.code != 0 {
		w.WriteHeader(s.code)
		return
	}
	_, _ = io.WriteString(w, `{"stored":1}`)
}

func newSyncer(url string, clock *time.Time) *syncer {
	return &syncer{url: url, client: &http.Client{Timeout: 5 * time.Second}, st: &state{Files: map[string]fileState{}},
		save: func() {}, tokens: map[string]*tokenStatus{}, now: func() time.Time { return *clock }}
}

func TestFindsEveryAccount(t *testing.T) {
	root := t.TempDir()
	writeSaved(t, root, "ONE", saved(""))
	writeSaved(t, root, "TWO", saved(""))
	_ = os.MkdirAll(filepath.Join(root, "_retail_", "WTF", "Account", "ONE", "SavedVariables"), 0o755)
	if got := expandRoots([]string{filepath.Join(filepath.Dir(root), "*"), filepath.Join(root, "missing")}); len(got) != 1 || got[0] != root {
		t.Fatalf("expandRoots = %v", got)
	}
	if got := findSavedFiles([]string{root, root}); len(got) != 2 {
		t.Fatalf("findSavedFiles = %v", got)
	}
}

func TestFoldersAreNamesNotPatterns(t *testing.T) {
	root := filepath.Join(t.TempDir(), "Games [SSD]", "World of Warcraft")
	writeSaved(t, root, "ONE", saved(""))
	if got := expandRoots([]string{root}); len(got) != 1 || got[0] != root {
		t.Fatalf("expandRoots = %v", got)
	}
	if got := findSavedFiles([]string{root}); len(got) != 1 {
		t.Fatalf("findSavedFiles = %v", got)
	}
}

func TestUploadAddressIsRemembered(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	st := loadState(path)
	if st.uploadURL() != defaultURL {
		t.Fatalf("no address given: %q", st.uploadURL())
	}
	st.setURL("https://other.example/v1/ledger/")
	saveState(path, st)
	if got := loadState(path).uploadURL(); got != "https://other.example/v1/ledger" {
		t.Fatalf("after a restart: %q", got)
	}
	st.setURL("default")
	if st.uploadURL() != defaultURL {
		t.Fatalf("back to the default: %q", st.uploadURL())
	}
}

func TestOneCopyPerUser(t *testing.T) {
	dir := t.TempDir()
	release, running, err := lockForTest(dir)
	if running || err != nil {
		t.Fatalf("first copy: running=%v err=%v", running, err)
	}
	if _, running, _ := lockForTest(dir); !running {
		t.Fatalf("a second copy did not see the first")
	}
	release()
	release, running, err = lockForTest(dir)
	if running || err != nil {
		t.Fatalf("after the first copy ended: running=%v err=%v", running, err)
	}
	release()
}

func TestToken(t *testing.T) {
	if got := readToken([]byte(saved(""))); got != testToken {
		t.Fatalf("readToken = %q", got)
	}
	if got := readToken([]byte(`["token"] = "short"`)); got != "" {
		t.Fatalf("readToken accepted %q", got)
	}
}

func TestUnregisteredTokenSendsNothingButARareQuestion(t *testing.T) {
	web := &site{}
	server := httptest.NewServer(web)
	defer server.Close()
	root := t.TempDir()
	writeSaved(t, root, "ONE", saved(""))
	clock := time.Now()
	s := newSyncer(server.URL, &clock)
	for i := 0; i < 20; i++ { // twenty minutes of polling
		s.pass([]string{root})
		clock = clock.Add(time.Minute)
	}
	if web.status != 1 || web.uploads != 0 {
		t.Fatalf("unregistered: %d status checks, %d uploads", web.status, web.uploads)
	}
	clock = clock.Add(recheckEvery)
	s.pass([]string{root})
	if web.status != 2 || web.uploads != 0 {
		t.Fatalf("after the wait: %d status checks, %d uploads", web.status, web.uploads)
	}
}

func TestUploadsOnceThenOnlyOnChange(t *testing.T) {
	web := &site{registered: true}
	server := httptest.NewServer(web)
	defer server.Close()
	root := t.TempDir()
	path := writeSaved(t, root, "ONE", saved(""))
	clock := time.Now()
	s := newSyncer(server.URL, &clock)
	s.pass([]string{root})
	s.pass([]string{root})
	if web.uploads != 1 || web.status != 1 || web.lastBody != saved("") {
		t.Fatalf("first file: %d uploads, %d status checks", web.uploads, web.status)
	}
	writeSaved(t, root, "ONE", saved("[\"sync\"] = true,\n"))
	s.pass([]string{root})
	if web.uploads != 2 || !strings.Contains(web.lastBody, "sync") {
		t.Fatalf("changed file: %d uploads", web.uploads)
	}
	// A file written a second ago may be half written: not read yet.
	writeSaved(t, root, "ONE", saved("[\"sync\"] = false,\n"))
	now := time.Now()
	_ = os.Chtimes(path, now, now)
	clock = now
	s.pass([]string{root})
	if web.uploads != 2 {
		t.Fatalf("fresh file was uploaded")
	}
}

func TestRevokedTokenAndRefusedFile(t *testing.T) {
	web := &site{registered: true}
	server := httptest.NewServer(web)
	defer server.Close()
	root := t.TempDir()
	writeSaved(t, root, "ONE", saved(""))
	clock := time.Now()
	s := newSyncer(server.URL, &clock)

	// 400: unreadable; 409: a record id that is not this token's. Neither is sent twice, and --status says why.
	for i, code := range []int{http.StatusBadRequest, http.StatusConflict} {
		web.code = code
		path := writeSaved(t, root, "ONE", saved(strings.Repeat("\n", i)))
		s.pass([]string{root})
		s.pass([]string{root})
		if web.uploads != i+1 {
			t.Fatalf("a file refused with %d was sent again: %d uploads", code, web.uploads)
		}
		if note := s.st.Files[path].Note; !strings.HasPrefix(note, strconv.Itoa(code)) {
			t.Fatalf("refusal %d not kept for --status: %q", code, note)
		}
	}

	web.code = 0
	writeSaved(t, root, "ONE", saved("[\"sync\"] = true,\n"))
	s.pass([]string{root}) // registered is remembered, the upload goes out
	web.registered = false
	writeSaved(t, root, "ONE", saved("[\"sync\"] = false,\n"))
	s.pass([]string{root}) // 401 on the upload
	before := web.status
	for i := 0; i < 10; i++ {
		s.pass([]string{root})
		clock = clock.Add(time.Minute)
	}
	if web.status != before {
		t.Fatalf("a revoked token kept asking: %d questions in ten minutes", web.status-before)
	}
}

func TestUnreachableSiteIsAskedAgainOnTheNextPass(t *testing.T) {
	web := &site{registered: true}
	server := httptest.NewServer(web)
	defer server.Close()
	gone := httptest.NewServer(web)
	gone.Close() // an address nothing answers on: the network is not up yet
	root := t.TempDir()
	writeSaved(t, root, "ONE", saved(""))
	clock := time.Now()
	s := newSyncer(gone.URL, &clock)
	s.pass([]string{root})
	if web.status != 0 || web.uploads != 0 {
		t.Fatalf("unreachable: %d status checks, %d uploads", web.status, web.uploads)
	}
	s.url = server.URL
	clock = clock.Add(pollEvery)
	s.pass([]string{root})
	if web.status != 1 || web.uploads != 1 {
		t.Fatalf("a minute later: %d status checks, %d uploads; no answer was taken for a refusal", web.status, web.uploads)
	}
}

func TestWowFoldersAreNotSearchedOnEveryPass(t *testing.T) {
	clock := time.Now()
	searches := 0
	var there []string
	finder := &rootFinder{find: func() []string { searches++; return there }, now: func() time.Time { return clock }}
	for i := 0; i < 3; i++ { // nothing found yet: every pass looks again
		finder.roots()
		clock = clock.Add(pollEvery)
	}
	if searches != 3 {
		t.Fatalf("nothing found: %d searches in 3 passes", searches)
	}
	there = []string{"/games/World of Warcraft"}
	for i := 0; i < 20; i++ {
		if got := finder.roots(); len(got) != 1 || got[0] != there[0] {
			t.Fatalf("roots = %v", got)
		}
		clock = clock.Add(pollEvery)
	}
	if searches != 4 {
		t.Fatalf("folder known: %d searches in 20 passes", searches-3)
	}
	clock = clock.Add(rediscoverEvery)
	finder.roots()
	if searches != 5 {
		t.Fatalf("after the wait: %d searches", searches-3)
	}
}

// door counts what reaches it and answers every request with one status code.
type door struct {
	code, hits, withToken int
}

func (d *door) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	d.hits++
	if r.Header.Get("Authorization") != "" {
		d.withToken++
	}
	w.WriteHeader(d.code)
}

func TestWindowAsksWhetherTheSiteIsUpWithoutAToken(t *testing.T) {
	web := &door{code: http.StatusUnauthorized}
	server := httptest.NewServer(web)
	defer server.Close()
	clock := time.Now()
	s := newSyncer(server.URL, &clock)
	changes := 0
	s.probeEvery, s.changed = probeEvery, func() { changes++ }
	for i := 0; i < 10; i++ { // ten minutes of polling, with no game installed
		s.pass(nil)
		clock = clock.Add(time.Minute)
	}
	if v := s.view(); web.hits != 1 || web.withToken != 0 || !v.Up || v.Files != 0 {
		t.Fatalf("%d requests, %d with a token, view %+v", web.hits, web.withToken, v)
	}
	if changes != 2 { // what was found of the game, then the site's answer: both on the first pass
		t.Fatalf("the window was told %d times of two changes", changes)
	}
	web.code = http.StatusServiceUnavailable // the front door answers, the site behind it does not
	s.pass(nil)
	if v := s.view(); web.hits != 2 || v.Up || !v.Checked.Equal(clock) {
		t.Fatalf("site down: %d requests, view %+v", web.hits, v)
	}
	server.Close()
	clock = clock.Add(probeEvery)
	s.pass(nil)
	if v := s.view(); v.Up || !v.Checked.Equal(clock) {
		t.Fatalf("site gone: view %+v", v)
	}
}

func TestNoWindowNoQuestion(t *testing.T) {
	web := &door{code: http.StatusUnauthorized}
	server := httptest.NewServer(web)
	defer server.Close()
	clock := time.Now()
	s := newSyncer(server.URL, &clock)
	s.pass(nil)
	if web.hits != 0 {
		t.Fatalf("%d requests from a program with no window and no saved file", web.hits)
	}
}

func TestLastSyncIsRemembered(t *testing.T) {
	web := &site{registered: true}
	server := httptest.NewServer(web)
	defer server.Close()
	root := t.TempDir()
	writeSaved(t, root, "ONE", saved(""))
	clock := time.Now()
	s := newSyncer(server.URL, &clock)
	s.pass([]string{root})
	if v := s.view(); web.uploads != 1 || !v.LastSync.Equal(clock) || !s.st.LastSync.Equal(clock) || !v.Up || v.Files != 1 {
		t.Fatalf("%d uploads, view %+v, state %v", web.uploads, v, s.st.LastSync)
	}
	path := filepath.Join(t.TempDir(), "state.json")
	saveState(path, s.st)
	if got := loadState(path).LastSync; !got.Equal(clock) {
		t.Fatalf("read back %v, wrote %v", got, clock)
	}
}

func TestSettingsStartWithTheSessionAndNoDetailsUnlessSwitched(t *testing.T) {
	path := filepath.Join(t.TempDir(), "state.json")
	st := loadState(path) // no file yet: a first start
	if !st.autostart() || st.debug() {
		t.Fatalf("defaults: autostart %v, debug %v", st.autostart(), st.debug())
	}
	saveState(path, st)
	if data, _ := os.ReadFile(path); strings.Contains(string(data), "autostart") || strings.Contains(string(data), "debug") {
		t.Fatalf("the defaults are written down: %s", data)
	}
	st.change(func() { st.NoAutostart, st.Debug = true, true })
	saveState(path, st)
	if again := loadState(path); again.autostart() || !again.debug() {
		t.Fatalf("settings not remembered: autostart %v, debug %v", again.autostart(), again.debug())
	}
}

func TestDetailsSayWhyTheSiteIsNotReached(t *testing.T) {
	t.Setenv("LC_ALL", "C")
	web := &door{code: http.StatusUnauthorized}
	server := httptest.NewServer(web)
	clock := time.Now()
	s := newSyncer(server.URL, &clock)
	s.logPath = "sync.log"
	ask := func() view {
		_, _, _ = s.request("GET", "status", "", nil)
		return s.view()
	}
	if v := ask(); !v.Up || v.Problem != "" {
		t.Fatalf("an answer is no problem: %+v", v)
	}
	if got := s.details(); got != "Uploads to "+server.URL+"\nLog: sync.log" {
		t.Fatalf("details with nothing wrong: %q", got)
	}
	web.code = http.StatusBadGateway
	if v := ask(); v.Up || !strings.Contains(v.Problem, "502") {
		t.Fatalf("a gateway's answer: %+v", v)
	}
	server.Close()
	if v := ask(); v.Up || !strings.HasPrefix(v.Problem, texts["noconnect"][0]+" (") {
		t.Fatalf("nobody listening: %+v", v)
	}
	if !strings.Contains(s.details(), texts["noconnect"][0]) {
		t.Fatalf("the details leave the problem out: %q", s.details())
	}
	s.url = "http://rookieledger.invalid" // a name that never resolves (RFC 6761)
	if v := ask(); v.Up || !strings.HasPrefix(v.Problem, texts["nodns"][0]) {
		t.Fatalf("a name not found: %+v", v)
	}
	s.url, s.client.Timeout = "http://"+hang(t), 200*time.Millisecond
	if v := ask(); v.Up || !strings.HasPrefix(v.Problem, texts["timeout"][0]) {
		t.Fatalf("no answer in time: %+v", v)
	}
}

// hang is the address of a listener that takes connections and never answers.
func hang(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { l.Close() })
	return l.Addr().String()
}

func TestDetailsSayThatATokenWaits(t *testing.T) {
	t.Setenv("LC_ALL", "C")
	web := &site{}
	server := httptest.NewServer(web)
	defer server.Close()
	root := t.TempDir()
	writeSaved(t, root, "ONE", saved(""))
	clock := time.Now()
	s := newSyncer(server.URL, &clock)
	s.pass([]string{root})
	if !s.view().Waiting || !strings.Contains(s.details(), texts["dwaiting"][0]) {
		t.Fatalf("a token the site does not know: %+v, %q", s.view(), s.details())
	}
	web.registered = true
	clock = clock.Add(recheckEvery)
	s.pass([]string{root})
	if s.view().Waiting || strings.Contains(s.details(), texts["dwaiting"][0]) || web.uploads != 1 {
		t.Fatalf("once registered: %+v, %d uploads", s.view(), web.uploads)
	}
}

func TestGameDetailsSayWhatIsMissing(t *testing.T) {
	t.Setenv("LC_ALL", "C")
	dir := t.TempDir()
	mk := func(parts ...string) string {
		path := filepath.Join(append([]string{dir}, parts...)...)
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
		return path
	}
	// No install: the folders that were looked at and are something else, and a --wow-dir that is gone.
	retail := filepath.Dir(mk("Games", "World of Warcraft", "_retail_"))
	mk("Games", "World of Warcraft", "_classic_")
	empty := mk("Empty")
	gone := filepath.Join(dir, "gone")
	got := strings.Split(gameDetails(nil, []string{filepath.Join(dir, "*", "World of Warcraft"), retail,
		filepath.Join(retail, "_retail_"), filepath.Join(dir, "none"), empty}, []string{gone}), "\n")
	want := []string{texts["dnofolder"][0], retail + " holds _classic_, _retail_, but not _forever_: WoW Forever is not installed there.",
		empty + " exists, but holds no game.", "The folder given with --wow-dir does not exist: " + gone}
	if strings.Join(got, "\n") != strings.Join(want, "\n") {
		t.Fatalf("no install:\n%s\nwanted:\n%s", strings.Join(got, "\n"), strings.Join(want, "\n"))
	}
	// An install, step by step up to the addon's first saved file.
	root := mk("Forever")
	mk("Forever", flavor)
	line := func() string { return gameDetails([]string{root}, nil, nil) }
	start := "Game: " + root + ", "
	if got := line(); got != start+"0 account(s), 0 with the addon's data."+texts["dnoaddon"][0] {
		t.Fatalf("no addon: %q", got)
	}
	mk("Forever", flavor, "Interface", "AddOns", "RookieLedger")
	if got := line(); got != start+"0 account(s), 0 with the addon's data."+texts["dnologin"][0] {
		t.Fatalf("never logged in: %q", got)
	}
	mk("Forever", flavor, "WTF", "Account", "ONE")
	mk("Forever", flavor, "WTF", "Account", "SavedVariables") // not an account
	if got := line(); got != start+"1 account(s), 0 with the addon's data."+texts["dnologout"][0] {
		t.Fatalf("nothing saved yet: %q", got)
	}
	writeSaved(t, root, "ONE", saved(""))
	if got := line(); got != start+"1 account(s), 1 with the addon's data." {
		t.Fatalf("all there: %q", got)
	}
}

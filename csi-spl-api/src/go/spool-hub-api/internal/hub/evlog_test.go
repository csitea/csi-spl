package hub

import (
	"bytes"
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/evlog"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 162 section 10.4.2, row T3 (SPL-5882): source (a) of the backend
// error log. Cases C30-C33, C43 and the hub half of C44 (10.9), on the
// memory store.

// evlogBuf is a log sink safe for the hub's concurrent writes.
type evlogBuf struct {
	mu sync.Mutex
	b  bytes.Buffer
}

func (b *evlogBuf) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.b.Write(p)
}

// lines answers the JSON log lines whose message is msg.
func (b *evlogBuf) lines(t *testing.T, msg string) []map[string]any {
	t.Helper()
	b.mu.Lock()
	defer b.mu.Unlock()
	var out []map[string]any
	for _, l := range strings.Split(strings.TrimSpace(b.b.String()), "\n") {
		var m map[string]any
		if l == "" || json.Unmarshal([]byte(l), &m) != nil {
			continue
		}
		if m["message"] == msg {
			out = append(out, m)
		}
	}
	return out
}

// failStore is the memory store whose error-log writes fail (C33) and
// whose every revocation read fails (C44), each call counted.
type failStore struct {
	*store.Memory
	calls atomic.Int64
}

var errStoreDown = errors.New("store down: postgres://evlog:secret-pw@db.example.com:5432/spool")

func (f *failStore) UpsertSystemErrorGroup(context.Context, store.LogEvent) (store.LogEvent, error) {
	f.calls.Add(1)
	return store.LogEvent{}, errStoreDown
}

func (f *failStore) AddHumanEvents(context.Context, string, []store.HumanEvent, time.Time) (int, error) {
	f.calls.Add(1)
	return 0, errStoreDown
}

func (f *failStore) SessionRevocations(context.Context, time.Time) (map[string]time.Time, error) {
	f.calls.Add(1)
	return nil, errStoreDown
}

func (f *failStore) RevokeSessions(context.Context, string, time.Time) error {
	f.calls.Add(1)
	return errStoreDown
}

const evlogTestSessionKey = "evlog-test-session-key-0123456789abcdef"

// evlogRig is a hub with a real sign-in surface (its cookie checked by
// auth.Handler.HumanFromCookie), a hooked JSON logger and one test route
// per behaviour, all behind the hub's middleware.
type evlogRig struct {
	srv  *Server
	mem  *store.Memory
	fail *failStore // nil unless the rig was made failing
	logs *evlogBuf
	log  zerolog.Logger
	cfg  *auth.Config
	h    http.Handler
	now  time.Time
}

func newEvlogRig(t *testing.T, failing bool) *evlogRig {
	t.Helper()
	rg := &evlogRig{mem: store.NewMemory(), logs: &evlogBuf{}, now: time.Now().UTC()}
	var st store.Store = rg.mem
	var rev auth.SessionRevoker
	if failing {
		rg.fail = &failStore{Memory: rg.mem}
		st, rev = rg.fail, rg.fail
	}
	cfg, err := auth.LoadFrom("lde", map[string]string{
		"SPOOL_HUB_AUTH_PROVIDERS":            "google",
		"SPOOL_HUB_AUTH_SESSION_KEY":          evlogTestSessionKey,
		"SPOOL_HUB_AUTH_APP_URL":              "http://wui.test",
		"SPOOL_HUB_AUTH_COOKIE_SECURE":        "false",
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID":     "gid",
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET": "gsecret",
		"SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI":  "http://login.test/api/v1/auth/google/callback",
	})
	if err != nil {
		t.Fatal(err)
	}
	rg.cfg = cfg
	hook := NewEvlogHook()
	rg.log = zerolog.New(rg.logs).Hook(hook)
	srv, err := New(Options{Store: st, Blob: blob.Dir{Root: t.TempDir()}, Log: rg.log,
		Auth:              auth.New(cfg, zerolog.Nop(), auth.Options{Revocations: rev}),
		TenantHostPattern: "{tenant}.evlog.test", HelloSkew: 300 * time.Second, HelloTimeout: 2 * time.Second,
		UploadTokenTTL: 5 * time.Minute, QueueTTL: time.Hour, QueueMaxPerBox: 10, Version: "test"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(srv.Shutdown)
	hook.Attach(srv.Evlog())
	rg.srv = srv
	mux := http.NewServeMux()
	mux.HandleFunc("GET /v1/evlog-test/fail/{id}", func(w http.ResponseWriter, r *http.Request) {
		writeErrCause(w, http.StatusInternalServerError, "db_down", "the database is down",
			errors.New("query "+r.PathValue("id")+" failed after 3 tries"))
	})
	mux.HandleFunc("GET /v1/evlog-test/other", func(w http.ResponseWriter, _ *http.Request) {
		writeErr(w, http.StatusServiceUnavailable, "unavailable", "try later")
	})
	mux.HandleFunc("GET /v1/evlog-test/panic", func(http.ResponseWriter, *http.Request) {
		panic("leak Bearer evlogPlantedToken0123456789 by someone.planted@example.com via postgres://u:planted-pw@db.example.com/spool")
	})
	rg.h = srv.middleware(mux)
	return rg
}

// admit registers a person and answers their HUM-* id.
func (rg *evlogRig) admit(t *testing.T, subject string) string {
	t.Helper()
	hum, err := rg.mem.Admit(context.Background(), store.Identity{Provider: "google", Subject: subject}, "", store.AdmitPolicy{}, rg.now)
	if err != nil {
		t.Fatal(err)
	}
	return hum
}

// cookie seals a session the way auth signs one (token.go: HMAC-SHA256
// under the session subkey, base64url payload "." base64url MAC).
func (rg *evlogRig) cookie(t *testing.T, hum string, exp time.Time) *http.Cookie {
	t.Helper()
	sub := hmac.New(sha256.New, []byte(evlogTestSessionKey))
	sub.Write([]byte("spool-auth-session-v1"))
	raw, err := json.Marshal(auth.Session{V: 1, Provider: "google", Subject: "s", HumanID: hum, IssuedAt: rg.now.Unix(), Exp: exp.Unix()})
	if err != nil {
		t.Fatal(err)
	}
	payload := base64.RawURLEncoding.EncodeToString(raw)
	m := hmac.New(sha256.New, sub.Sum(nil))
	m.Write([]byte(payload))
	return &http.Cookie{Name: rg.cfg.CookieName, Value: payload + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil)), HttpOnly: true, Secure: true}
}

// do sends one request through the middleware and answers the recorder.
func (rg *evlogRig) do(t *testing.T, path string, c *http.Cookie) *httptest.ResponseRecorder {
	t.Helper()
	r := httptest.NewRequest(http.MethodGet, path, nil)
	if c != nil {
		r.AddCookie(c)
	}
	w := httptest.NewRecorder()
	rg.h.ServeHTTP(w, r)
	return w
}

// system answers every System log row.
func (rg *evlogRig) system(t *testing.T) []store.LogEvent {
	t.Helper()
	rows, err := rg.mem.SystemEventsPage(context.Background(), 0, 1000)
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

// mine answers a person's Mine rows.
func (rg *evlogRig) mine(t *testing.T, hum string) []store.HumanEvent {
	t.Helper()
	rows, err := rg.mem.HumanEventsPage(context.Background(), hum, 0, 1000)
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

// byKind answers the System rows of kind.
func byKind(rows []store.LogEvent, kind string) []store.LogEvent {
	var out []store.LogEvent
	for _, r := range rows {
		if r.Kind == kind {
			out = append(out, r)
		}
	}
	return out
}

// panicLoop panics once in a supervised loop whose context carries the
// rig's sightings, then ends.
func (rg *evlogRig) panicLoop(t *testing.T, name string) {
	t.Helper()
	ctx, cancel := context.WithCancel(WithEvlog(context.Background(), rg.srv.Evlog()))
	defer cancel()
	runs := 0
	supervise(ctx, rg.log, name, func(context.Context) {
		if runs++; runs == 1 {
			panic("loop tick failed")
		}
		cancel()
	}, time.Millisecond, time.Second, time.Now)
}

// C30: a handler panic whose value holds a bearer token, an email and a DSN
// stores a row with none of them.
func TestEvlogPanicRowIsRedacted(t *testing.T) {
	rg := newEvlogRig(t, false)
	if w := rg.do(t, "/v1/evlog-test/panic", nil); w.Code != http.StatusInternalServerError {
		t.Fatalf("panic answered %d, want 500", w.Code)
	}
	rg.srv.FlushEvlog(context.Background())
	rows := byKind(rg.system(t), store.LogKindErrPanic)
	if len(rows) != 1 {
		t.Fatalf("error.panic rows = %d, want 1: %+v", len(rows), rg.system(t))
	}
	for _, leak := range []string{"evlogPlantedToken0123456789", "someone.planted@example.com", "planted-pw", "postgres://"} {
		if strings.Contains(rows[0].Message, leak) || strings.Contains(rows[0].OriginRef, leak) {
			t.Errorf("stored row leaks %q: message %q", leak, rows[0].Message)
		}
	}
	if !strings.HasPrefix(rows[0].Message, "panic: leak Bearer <redacted>") {
		t.Errorf("message %q, want the redacted panic value", rows[0].Message)
	}
}

// C31: a handler 5xx, a handler panic and a loop panic each add one
// sighting of their kind; 100 identical 5xx then one flush write ONE row
// with n = 100 (red control: a flush that inserts per sighting writes 100).
func TestEvlogOneUpsertPerGroup(t *testing.T) {
	rg := newEvlogRig(t, false)
	rg.do(t, "/v1/evlog-test/other", nil)
	rg.do(t, "/v1/evlog-test/panic", nil)
	rg.panicLoop(t, "evlog-test-loop")
	rg.srv.FlushEvlog(context.Background())
	rows := rg.system(t)
	for _, kind := range []string{store.LogKindErrHTTPServer, store.LogKindErrPanic, store.LogKindErrLoopPanic} {
		if got := byKind(rows, kind); len(got) != 1 || got[0].N != 1 {
			t.Errorf("%s: %d rows %+v, want one row with n=1", kind, len(got), got)
		}
	}
	if got := byKind(rows, store.LogKindErrLoopPanic); len(got) == 1 && got[0].OriginRef != "evlog-test-loop" {
		t.Errorf("loop panic origin_ref %q, want the loop name", got[0].OriginRef)
	}
	if len(byKind(rows, store.LogKindErrLog)) != 0 {
		t.Errorf("an error.log row was written for a line that has its own sighting: %+v", byKind(rows, store.LogKindErrLog))
	}

	rg = newEvlogRig(t, false)
	for i := 0; i < 100; i++ { // the id (in the error text) differs per request: Normalize folds it, one group
		if w := rg.do(t, "/v1/evlog-test/fail/"+strconv.Itoa(1000+i), nil); w.Code != 500 {
			t.Fatalf("request %d answered %d", i, w.Code)
		}
	}
	rg.srv.FlushEvlog(context.Background())
	got := byKind(rg.system(t), store.LogKindErrHTTPServer)
	if len(got) != 1 || got[0].N != 100 {
		t.Fatalf("100 identical 5xx then one flush: %d rows (n of the first: %v), want ONE row with n=100", len(got), nNs(got))
	}
	if got[0].OriginRef != "GET /v1/evlog-test/fail/{id}" || got[0].Fingerprint == "" || got[0].Actor != "hub" {
		t.Errorf("row %+v: want origin_ref the mux pattern, a fingerprint, actor hub", got[0])
	}
	rg.srv.FlushEvlog(context.Background()) // nothing new: no write, the row stays
	if again := byKind(rg.system(t), store.LogKindErrHTTPServer); len(again) != 1 || again[0].N != 100 {
		t.Fatalf("an empty flush changed the group: %v", nNs(again))
	}
}

func nNs(rows []store.LogEvent) []int {
	out := make([]int, 0, len(rows))
	for _, r := range rows {
		out = append(out, r.N)
	}
	return out
}

// evlogTestWriter is a hub function that writes an ERROR line (C32 anchors
// on it).
func evlogTestWriter(log zerolog.Logger, n int) {
	log.Error().Int("n", n).Msgf("disk quota hit on volume %d", n)
}

// C32: an Error() line from a hub function adds one error.log sighting
// anchored on that function; an http 5xx line, an event-log-write-failed
// line, a loop panic line and a warning add none (no double, no loop).
func TestEvlogHookCountsOtherErrorLines(t *testing.T) {
	rg := newEvlogRig(t, false)
	evlogTestWriter(rg.log, 7)
	evlogTestWriter(rg.log, 8)
	for _, msg := range []string{httpServerErrMsg, handlerPanicMsg, EvlogUnwrittenMsg, LoopPanicMsg} {
		rg.log.Error().Msg(msg)
	}
	rg.log.Warn().Msg("only a warning")
	rg.log.Info().Msg("all fine")
	tk := rg.srv.Evlog().take(time.Now())
	if len(tk.groups) != 1 {
		t.Fatalf("groups %+v, want exactly one (the error.log line)", tk.groups)
	}
	g := tk.groups[0]
	const fn = "github.com/csitea/csi-spl/spool-hub-api/internal/hub.evlogTestWriter"
	if g.Kind != store.LogKindErrLog || g.N != 2 || g.Fingerprint != evlog.Fingerprint(store.LogKindErrLog, "disk quota hit on volume 7", fn) {
		t.Fatalf("group %+v: want error.log, n=2, anchored on %s", g, fn)
	}
	if g.Message != "disk quota hit on volume <n>" {
		t.Errorf("message %q, want the normalized line", g.Message)
	}
}

// C33: a flush with the store failing writes one event-log-write-failed
// line per group with its fp and n (redacted), and the request that caused
// the error answered as before, without a store call of the error path.
func TestEvlogUnwrittenLinePerGroup(t *testing.T) {
	want := newEvlogRig(t, false).do(t, "/v1/evlog-test/other", nil)
	rg := newEvlogRig(t, true)
	hum := rg.admit(t, "evlog-c33")
	for i := 0; i < 3; i++ {
		w := rg.do(t, "/v1/evlog-test/other", rg.cookie(t, hum, rg.now.Add(time.Hour)))
		if w.Code != want.Code || w.Body.String() != want.Body.String() {
			t.Fatalf("answer %d %q, want %d %q as without the event log", w.Code, w.Body.String(), want.Code, want.Body.String())
		}
	}
	rg.do(t, "/v1/evlog-test/panic", nil)
	if n := rg.fail.calls.Load(); n != 0 {
		t.Fatalf("the error path made %d store calls before the flush, want 0", n)
	}
	rg.srv.FlushEvlog(context.Background())
	lines := rg.logs.lines(t, EvlogUnwrittenMsg)
	var groups, mine int
	ns := map[string]float64{}
	for _, l := range lines {
		if strings.Contains(l["error"].(string), "secret-pw") {
			t.Errorf("unwritten line leaks the DSN: %v", l)
		}
		if _, ok := l["human_id"]; ok {
			t.Errorf("unwritten line names a person: %v", l)
		}
		if l["target"] == "mine" {
			mine++
			continue
		}
		groups++
		ns[l["kind"].(string)] = l["n"].(float64)
		if fp, _ := l["fp"].(string); len(fp) != 16 {
			t.Errorf("unwritten line without its fp: %v", l)
		}
	}
	if groups != 2 || ns[store.LogKindErrHTTPServer] != 3 || ns[store.LogKindErrPanic] != 1 || mine != 1 {
		t.Fatalf("unwritten lines: %d group lines %v and %d mine lines, want 2 (http_server n=3, panic n=1) and 1", groups, ns, mine)
	}
	if extra := rg.srv.Evlog().take(time.Now()); len(extra.groups) != 0 {
		t.Fatalf("the unwritten lines were counted again as sightings: %+v", extra.groups)
	}
}

// SPL-6240: a group's unwritten line carries exactly one "message" key,
// zerolog's own (EvlogUnwrittenMsg), and the group's text under
// "group_message" (the field the box reader's rule 1 reads, 10.4.4): with
// the text under "message" too, a JSON reader keeps only one of the two.
func TestEvlogUnwrittenLineOneMessageKey(t *testing.T) {
	ok := newEvlogRig(t, false)
	ok.do(t, "/v1/evlog-test/panic", nil)
	ok.srv.FlushEvlog(context.Background())
	sys := ok.system(t)
	if len(sys) != 1 || sys[0].Message == "" {
		t.Fatalf("system rows %+v, want the one panic group with its text", sys)
	}
	rg := newEvlogRig(t, true)
	rg.do(t, "/v1/evlog-test/panic", nil)
	rg.srv.FlushEvlog(context.Background())
	rg.logs.mu.Lock()
	raw := strings.Split(strings.TrimSpace(rg.logs.b.String()), "\n")
	rg.logs.mu.Unlock()
	var groups int
	for _, l := range raw {
		if !strings.Contains(l, EvlogUnwrittenMsg) || strings.Contains(l, `"target":"mine"`) {
			continue
		}
		groups++
		if n := strings.Count(l, `"message":`); n != 1 {
			t.Errorf("unwritten line carries %d message keys, want 1: %s", n, l)
		}
		var m map[string]any
		if err := json.Unmarshal([]byte(l), &m); err != nil {
			t.Fatal(err)
		}
		if m["message"] != EvlogUnwrittenMsg || m["group_message"] != sys[0].Message {
			t.Errorf("message %q group_message %q, want %q and %q", m["message"], m["group_message"], EvlogUnwrittenMsg, sys[0].Message)
		}
	}
	if groups != 1 {
		t.Fatalf("%d group unwritten lines, want 1: %v", groups, raw)
	}
}

// C43 (Q4 B): a 5xx of a signed-in person, then one flush, writes one
// source=hub row in that person's Mine log and names them on the group; 100
// identical 5xx of that person write ONE Mine row ending " (x100)" (red
// control: one Mine row per sighting writes 100); a 5xx with no cookie, a
// box request and a loop panic write no Mine row and keep human_id.
func TestEvlogMineCopy(t *testing.T) {
	rg := newEvlogRig(t, false)
	hum := rg.admit(t, "evlog-c43")
	c := rg.cookie(t, hum, rg.now.Add(time.Hour))
	rg.do(t, "/v1/evlog-test/fail/1", c)
	rg.srv.FlushEvlog(context.Background())
	g := byKind(rg.system(t), store.LogKindErrHTTPServer)
	rows := rg.mine(t, hum)
	if len(g) != 1 || g[0].HumanID != hum {
		t.Fatalf("group %+v, want one with human_id %s", g, hum)
	}
	if len(rows) != 1 {
		t.Fatalf("Mine rows %d, want 1", len(rows))
	}
	r := rows[0]
	if r.Source != "hub" || r.Route != "GET /v1/evlog-test/fail/{id}" || r.Status != 500 || r.Code != "db_down" ||
		r.Origin != "evlog:"+g[0].Fingerprint || r.Method != http.MethodGet || r.Path != "" || r.OccurredAt == nil {
		t.Fatalf("Mine row %+v: want source hub, the route, 500, db_down, origin evlog:<fp>, no path", r)
	}
	if strings.Contains(r.Message, "(x") {
		t.Errorf("one sighting carries a count: %q", r.Message)
	}

	for i := 0; i < 100; i++ {
		rg.do(t, "/v1/evlog-test/fail/2", c)
	}
	rg.do(t, "/v1/evlog-test/fail/3", nil)                                                                                        // no cookie
	rg.do(t, "/v1/evlog-test/fail/4", &http.Cookie{Name: "spool_box", Value: "box-token-of-a-box", HttpOnly: true, Secure: true}) // a box
	rg.panicLoop(t, "evlog-test-loop")
	rg.srv.FlushEvlog(context.Background())
	rows = rg.mine(t, hum)
	if len(rows) != 2 {
		t.Fatalf("after 100 identical 5xx in one flush: %d Mine rows, want 2 (1 + ONE for the 100)", len(rows))
	}
	if !strings.HasSuffix(rows[0].Message, " (x100)") {
		t.Fatalf("newest Mine row %q, want the suffix (x100)", rows[0].Message)
	}
	g = byKind(rg.system(t), store.LogKindErrHTTPServer)
	if len(g) != 1 || g[0].N != 103 || g[0].HumanID != hum {
		t.Fatalf("group %+v, want n=103 and human_id still %s", g, hum)
	}
	if lp := byKind(rg.system(t), store.LogKindErrLoopPanic); len(lp) != 1 || lp[0].HumanID != "" {
		t.Fatalf("loop panic group %+v, want one with no person", lp)
	}
}

// C43: at most 20 Mine rows per person per flush, the rest folded into the
// 20th as " (+<k> more)".
func TestEvlogMineCapPerPerson(t *testing.T) {
	rg := newEvlogRig(t, false)
	hum := rg.admit(t, "evlog-cap")
	e := rg.srv.Evlog()
	for i := 0; i < 23; i++ {
		e.add(evlogSight{Sighting: evlog.Sighting{Kind: store.LogKindErrHTTPServer, Message: "500 x at a.go:1",
			Anchor: "GET /r" + string(rune('a'+i)) + " x", At: rg.now.Add(time.Duration(i) * time.Millisecond)},
			originRef: "GET /r", human: hum, method: "GET", route: "GET /r", code: "x", status: 500})
	}
	rg.srv.FlushEvlog(context.Background())
	rows := rg.mine(t, hum)
	if len(rows) != 20 || !strings.HasSuffix(rows[0].Message, " (+3 more)") {
		t.Fatalf("%d Mine rows, newest %q: want 20, the 20th ending (+3 more)", len(rows), rows[0].Message)
	}
}

// C44 (Q4 B), the hub half: with a store whose every call fails, a 5xx with
// a valid cookie still names the person on the sighting; a forged or
// expired cookie names none.
func TestEvlogPersonWithoutTheStore(t *testing.T) {
	rg := newEvlogRig(t, true)
	const hum = "HUM-4242" // not in any store: the cookie alone names it
	valid := rg.cookie(t, hum, rg.now.Add(time.Hour))
	forged := &http.Cookie{Name: valid.Name, Value: valid.Value[:strings.Index(valid.Value, ".")] + ".AAAA", HttpOnly: true, Secure: true}
	expired := rg.cookie(t, hum, rg.now.Add(-time.Minute))
	for _, tc := range []struct {
		name string
		c    *http.Cookie
		want string
	}{{"valid", valid, hum}, {"forged", forged, ""}, {"expired", expired, ""}, {"none", nil, ""}} {
		rg.do(t, "/v1/evlog-test/other", tc.c)
		tk := rg.srv.Evlog().take(time.Now())
		if len(tk.groups) != 1 {
			t.Fatalf("%s: groups %+v", tc.name, tk.groups)
		}
		if got := tk.meta[tk.groups[0].Fingerprint].human; got != tc.want {
			t.Errorf("%s cookie: sighting person %q, want %q", tc.name, got, tc.want)
		}
	}
	if n := rg.fail.calls.Load(); n != 0 {
		t.Fatalf("naming the person made %d store calls, want 0", n)
	}
}

// The trace field (10.4.2): the access line and the 5xx line carry Cloud
// Logging's trace from X-Cloud-Trace-Context once the project is set; a
// header that is not a trace id adds nothing.
func TestEvlogTraceField(t *testing.T) {
	rg := newEvlogRig(t, false)
	send := func(hdr string) {
		r := httptest.NewRequest(http.MethodGet, "/v1/evlog-test/other", nil)
		r.Header.Set("X-Cloud-Trace-Context", hdr)
		rg.h.ServeHTTP(httptest.NewRecorder(), r)
	}
	const id = "0123456789abcdef0123456789ABCDEF"
	send(id + "/1;o=1")
	if l := rg.logs.lines(t, "http"); len(l) != 1 || l[0][evlogTraceKey] != nil {
		t.Fatalf("no project: access line %v, want no trace field", l)
	}
	rg.srv.Evlog().SetTraceProject("evlog-test-project")
	send(id + "/1;o=1")
	send("not-a-trace/1")
	want := "projects/evlog-test-project/traces/" + strings.ToLower(id)
	for _, msg := range []string{"http", httpServerErrMsg} {
		l := rg.logs.lines(t, msg)
		if len(l) != 3 || l[1][evlogTraceKey] != want || l[2][evlogTraceKey] != nil {
			t.Errorf("%s lines %v: want the 2nd with trace %s, the 3rd with none", msg, l, want)
		}
	}
}

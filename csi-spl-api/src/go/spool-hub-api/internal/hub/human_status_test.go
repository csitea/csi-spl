package hub_test

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"net/http"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 096 L2 (tests 10.1): a member's manual status. Memory, and Postgres
// under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

// statusClock is a settable hub clock.
type statusClock struct {
	mu sync.Mutex
	at time.Time
}

func (c *statusClock) now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.at }
func (c *statusClock) add(d time.Duration) {
	c.mu.Lock()
	defer c.mu.Unlock()
	c.at = c.at.Add(d)
}

func statusEnv(t *testing.T) (*env, *statusClock) {
	clk := &statusClock{at: time.Now().UTC().Truncate(time.Second)}
	return rbacEnv(t, func(o *hub.Options) { o.Now = clk.now }), clk
}

// rosterStatus is the roster's `status` of hum in tid, nil when omitted.
func rosterStatus(t *testing.T, e *env, tid, as, hum string) map[string]any {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/view/roster", as, nil)
	if code != http.StatusOK {
		t.Fatalf("roster: %d %v", code, out)
	}
	humans, _ := out["humans"].([]any)
	for _, h := range humans {
		m := h.(map[string]any)
		if m["human_id"] == hum {
			st, _ := m["status"].(map[string]any)
			return st
		}
	}
	t.Fatalf("roster of %s lists no %s: %v", tid, hum, out)
	return nil
}

func putStatus(t *testing.T, e *env, tid, as string, body map[string]any) (int, map[string]any) {
	t.Helper()
	return call(t, e, tid, http.MethodPut, "/v1/me/status", as, body)
}

func TestHumanStatusSetClear(t *testing.T) {
	e, clk := statusEnv(t)
	tid, _ := e.tenant()
	a := seat(t, e, tid, rbac.Developer)
	b := seat(t, e, tid, rbac.Developer)
	until := clk.now().Add(time.Hour).Format(time.RFC3339)

	code, out := putStatus(t, e, tid, a, map[string]any{"state": "busy", "note": "  In a\nmeeting\x07 ", "until": until, "pause_notify": true})
	if code != http.StatusOK || out["state"] != "busy" || out["note"] != "In a meeting" || out["until"] != until || out["pause_notify"] != true {
		t.Fatalf("put: %d %v", code, out)
	}
	st := rosterStatus(t, e, tid, b, a)
	if st["state"] != "busy" || st["note"] != "In a meeting" || st["until"] != until {
		t.Fatalf("b reads a's status: %v", st)
	}
	if _, leaked := st["pause_notify"]; leaked {
		t.Fatalf("the roster shows pause_notify: %v", st)
	}
	if st := rosterStatus(t, e, tid, a, b); st != nil {
		t.Fatalf("CONTROL: b set nothing, roster shows %v", st)
	}
	if code, me := call(t, e, tid, http.MethodGet, "/v1/me/status", a, nil); code != http.StatusOK || me["state"] != "busy" || me["pause_notify"] != true {
		t.Fatalf("get own: %d %v", code, me)
	}

	// No note and no until: busy with no end.
	if code, out := putStatus(t, e, tid, a, map[string]any{"state": "unavailable"}); code != http.StatusOK || out["until"] != nil || out["note"] != nil {
		t.Fatalf("put no end: %d %v", code, out)
	}
	if st := rosterStatus(t, e, tid, b, a); st["state"] != "unavailable" || st["until"] != nil {
		t.Fatalf("no end: %v", st)
	}

	if code, out := call(t, e, tid, http.MethodDelete, "/v1/me/status", a, nil); code != http.StatusOK || out["state"] != "available" {
		t.Fatalf("delete: %d %v", code, out)
	}
	if st := rosterStatus(t, e, tid, b, a); st != nil {
		t.Fatalf("after clear the roster shows %v", st)
	}
	if code, me := call(t, e, tid, http.MethodGet, "/v1/me/status", a, nil); code != http.StatusOK || me["state"] != "available" {
		t.Fatalf("get after clear: %d %v", code, me)
	}
	// PUT available clears as well.
	putStatus(t, e, tid, a, map[string]any{"state": "busy"})
	if code, _ := putStatus(t, e, tid, a, map[string]any{"state": "available"}); code != http.StatusOK || rosterStatus(t, e, tid, b, a) != nil {
		t.Fatalf("put available did not clear: %d", code)
	}
}

func TestHumanStatusExpiresOnRead(t *testing.T) {
	e, clk := statusEnv(t)
	tid, _ := e.tenant()
	a := seat(t, e, tid, rbac.Developer)
	b := seat(t, e, tid, rbac.Developer)
	hs := e.st.(store.HumanStatuses)
	ctx := context.Background()
	past := clk.now().Add(-time.Minute)
	for hum, until := range map[string]time.Time{a: past, b: clk.now().Add(time.Hour)} {
		if err := hs.PutHumanStatus(ctx, tid, store.HumanStatus{HumanID: hum, State: "unavailable", Until: until, SetAt: past, SetBy: hum}); err != nil {
			t.Fatal(err)
		}
	}
	if st := rosterStatus(t, e, tid, b, a); st != nil {
		t.Fatalf("an expired status shows with no sweep run: %v", st)
	}
	if st := rosterStatus(t, e, tid, a, b); st["state"] != "unavailable" {
		t.Fatalf("CONTROL: a live status is omitted: %v", st)
	}
	if code, me := call(t, e, tid, http.MethodGet, "/v1/me/status", a, nil); code != http.StatusOK || me["state"] != "available" {
		t.Fatalf("get own expired: %d %v", code, me)
	}
}

// waitStatusFrame reads raw frames until want arrives, byte for byte (the
// encoder's trailing newline aside); any other `status` frame first fails.
func waitStatusFrame(t *testing.T, w *wuiClient, want string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		_, raw, err := w.c.Read(ctx)
		if err != nil {
			t.Fatalf("waiting for %s: %v", want, err)
		}
		got := strings.TrimSpace(string(raw))
		if got == want {
			return
		}
		if strings.Contains(got, `"type":"status"`) {
			t.Fatalf("waiting for %s: got status frame %s", want, got)
		}
	}
}

// noStatusFrame fails when a `status` frame arrives within d. The read's
// timeout closes the socket, so it is a socket's last check.
func noStatusFrame(t *testing.T, w *wuiClient, d time.Duration) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), d)
	defer cancel()
	for {
		_, raw, err := w.c.Read(ctx)
		if err != nil {
			return
		}
		if strings.Contains(string(raw), `"type":"status"`) {
			t.Fatalf("unexpected status frame: %s", raw)
		}
	}
}

func TestHumanStatusSweepFrame(t *testing.T) {
	e, clk := statusEnv(t)
	tid, _ := e.tenant()
	other, _ := e.tenant()
	a := seat(t, e, tid, rbac.Developer)
	b := seat(t, e, tid, rbac.Developer)
	x := seat(t, e, other, rbac.Developer)
	w := dialWUI(t, e, tid, b)
	xw := dialWUI(t, e, other, x)

	until := clk.now().Add(2 * time.Minute).Format(time.RFC3339)
	if code, out := putStatus(t, e, tid, a, map[string]any{"state": "busy", "note": "On leave", "until": until}); code != http.StatusOK {
		t.Fatalf("put: %d %v", code, out)
	}
	waitStatusFrame(t, w, `{"type":"status","peer":"`+a+`@box-wui","state":"busy","note":"On leave","until":"`+until+`"}`)

	// Not expired yet: the sweep deletes nothing (and the strict wait below
	// fails on any frame it would have sent).
	e.srv.Relay(context.Background())
	if m, _ := e.st.(store.HumanStatuses).HumanStatuses(context.Background(), tid, time.Time{}); len(m) != 1 {
		t.Fatalf("CONTROL: a live status was swept: %v", m)
	}

	clk.add(3 * time.Minute)
	e.srv.Relay(context.Background())
	waitStatusFrame(t, w, `{"type":"status","peer":"`+a+`@box-wui","state":"available"}`)

	m, err := e.st.(store.HumanStatuses).HumanStatuses(context.Background(), tid, time.Time{})
	if err != nil || len(m) != 0 {
		t.Fatalf("the sweep left rows: %v %v", m, err)
	}
	// At most once a minute per tenant: a second expired row waits.
	untilB := clk.now().Add(time.Second).Format(time.RFC3339)
	putStatus(t, e, tid, b, map[string]any{"state": "busy", "until": untilB})
	clk.add(30 * time.Second)
	e.srv.Relay(context.Background())
	if m, _ := e.st.(store.HumanStatuses).HumanStatuses(context.Background(), tid, time.Time{}); len(m) != 1 {
		t.Fatalf("swept twice within a minute: %v", m)
	}
	clk.add(31 * time.Second)
	e.srv.Relay(context.Background())
	waitStatusFrame(t, w, `{"type":"status","peer":"`+b+`@box-wui","state":"busy","until":"`+untilB+`"}`)
	waitStatusFrame(t, w, `{"type":"status","peer":"`+b+`@box-wui","state":"available"}`)
	noStatusFrame(t, xw, 200*time.Millisecond) // another workspace heard none of it
}

func TestHumanStatusTenantIsolation(t *testing.T) {
	e, _ := statusEnv(t)
	tid, _ := e.tenant()
	other, _ := e.tenant()
	a := seat(t, e, tid, rbac.Developer)
	x := seat(t, e, other, rbac.Developer)
	if code, out := putStatus(t, e, tid, a, map[string]any{"state": "unavailable"}); code != http.StatusOK {
		t.Fatalf("put: %d %v", code, out)
	}
	hs := e.st.(store.HumanStatuses)
	if m, err := hs.HumanStatuses(context.Background(), tid, time.Now()); err != nil || len(m) != 1 {
		t.Fatalf("CONTROL: workspace A reads %v %v", m, err)
	}
	if m, err := hs.HumanStatuses(context.Background(), other, time.Now()); err != nil || len(m) != 0 {
		t.Fatalf("workspace B reads A's rows: %v %v", m, err)
	}
	if code, out := call(t, e, other, http.MethodGet, "/v1/me/status", x, nil); code != http.StatusOK || out["state"] != "available" {
		t.Fatalf("B's own status: %d %v", code, out)
	}
	// A's member cannot write in B (not a member there).
	if code, _ := putStatus(t, e, other, a, map[string]any{"state": "busy"}); code == http.StatusOK {
		t.Fatalf("a non-member wrote a status in B")
	}
}

func TestHumanStatusOwnRowOnly(t *testing.T) {
	e, _ := statusEnv(t)
	tid, _ := e.tenant()
	a := seat(t, e, tid, rbac.Developer)
	b := seat(t, e, tid, rbac.Developer)
	if code, _ := putStatus(t, e, tid, a, map[string]any{"state": "busy", "human_id": b}); code != http.StatusBadRequest {
		t.Fatalf("a body naming another member: %d", code)
	}
	if st := rosterStatus(t, e, tid, a, b); st != nil {
		t.Fatalf("b's row was written: %v", st)
	}
	for _, m := range []string{http.MethodPut, http.MethodDelete, http.MethodGet} {
		if code, _ := call(t, e, tid, m, "/v1/me/status", "", map[string]any{"state": "busy"}); code != http.StatusForbidden {
			t.Fatalf("%s without a member session (an agent): %d", m, code)
		}
	}
	if code, _ := putStatus(t, e, tid, a, map[string]any{"state": "busy"}); code != http.StatusOK {
		t.Fatalf("CONTROL: own row: %d", code)
	}
	if st := rosterStatus(t, e, tid, a, b); st != nil {
		t.Fatalf("a's write landed on b: %v", st)
	}
}

func TestHumanStatusValidation(t *testing.T) {
	e, clk := statusEnv(t)
	tid, _ := e.tenant()
	a := seat(t, e, tid, rbac.Developer)
	now := clk.now()
	for name, body := range map[string]map[string]any{
		"unknown state":  {"state": "away"},
		"no state":       {"note": "x"},
		"note over 80":   {"state": "busy", "note": strings.Repeat("é", 81)},
		"until past":     {"state": "busy", "until": now.Add(-time.Minute).Format(time.RFC3339)},
		"until now":      {"state": "busy", "until": now.Format(time.RFC3339)},
		"until 91 days":  {"state": "busy", "until": now.Add(91 * 24 * time.Hour).Format(time.RFC3339)},
		"until not time": {"state": "busy", "until": "tomorrow"},
		"not an object":  nil,
	} {
		code, out := putStatus(t, e, tid, a, body)
		if code != http.StatusBadRequest {
			t.Errorf("%s: %d %v", name, code, out)
		}
	}
	if st := rosterStatus(t, e, tid, a, a); st != nil {
		t.Fatalf("a refusal stored %v", st)
	}
	for name, body := range map[string]map[string]any{
		"note of 80":     {"state": "busy", "note": strings.Repeat("é", 80)},
		"until 90 days":  {"state": "unavailable", "until": now.Add(90 * 24 * time.Hour).Format(time.RFC3339)},
		"until empty":    {"state": "busy", "until": ""},
		"note only ctrl": {"state": "busy", "note": "\x01\x02"},
	} {
		if code, out := putStatus(t, e, tid, a, body); code != http.StatusOK {
			t.Errorf("CONTROL %s: %d %v", name, code, out)
		}
	}
}

func TestWelcomeStatusSnapshot(t *testing.T) {
	e, _ := statusEnv(t)
	tid, _ := e.tenant()
	a := seat(t, e, tid, rbac.Developer)
	b := seat(t, e, tid, rbac.Developer)
	c := seat(t, e, tid, rbac.Developer)
	putStatus(t, e, tid, a, map[string]any{"state": "unavailable", "note": "On leave"})
	watch := dialWUI(t, e, tid, a)
	dialWUI(t, e, tid, b) // b online: one presence frame in the snapshot
	// b counts as online only after its welcome; wait until another socket
	// saw it, so c's snapshot is sure to carry it (CI raced here).
	watch.presence(b+"@box-wui", "online")

	v := dialWUI(t, e, tid, c)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	sawPresence := false
	for {
		_, raw, err := v.c.Read(ctx)
		if err != nil {
			t.Fatalf("no status frame in the snapshot: %v", err)
		}
		s := strings.TrimSpace(string(raw))
		if s == `{"peer":"`+b+`@box-wui","status":"online","type":"presence"}` {
			sawPresence = true // the presence frame byte for byte, as before
		}
		if strings.Contains(s, `"type":"status"`) {
			if !sawPresence {
				t.Fatalf("status frame before the presence snapshot: %s", s)
			}
			if want := `{"type":"status","peer":"` + a + `@box-wui","state":"unavailable","note":"On leave"}`; s != want {
				t.Fatalf("snapshot frame:\n got %s\nwant %s", s, want)
			}
			return
		}
	}
}

// seatTwice admits one identity to two workspaces; the hub hands back the
// same HUM-* both times.
func seatTwice(t *testing.T, e *env, t1, t2 string) string {
	t.Helper()
	h := e.st.(store.Humans)
	b := make([]byte, 5)
	rand.Read(b) //nolint:errcheck
	email := hex.EncodeToString(b) + "@example.com"
	now := time.Now()
	var hum string
	for _, tid := range []string{t1, t2} {
		if err := h.PutInvite(context.Background(), store.Invite{TenantID: tid, Email: email, Role: rbac.Developer,
			InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
			t.Fatal(err)
		}
		got, err := h.Admit(context.Background(), store.Identity{Provider: "google", Subject: "s-" + email, Email: email}, tid, store.AdmitPolicy{}, now)
		if err != nil {
			t.Fatal(err)
		}
		if hum != "" && got != hum {
			t.Fatalf("second admit made %s, want %s", got, hum)
		}
		hum = got
	}
	return hum
}

func TestHumanStatusAllWorkspaces(t *testing.T) {
	e, _ := statusEnv(t)
	t1, _ := e.tenant()
	t2, _ := e.tenant()
	a := seatTwice(t, e, t1, t2)
	b1, b2 := seat(t, e, t1, rbac.Developer), seat(t, e, t2, rbac.Developer)

	putStatus(t, e, t1, a, map[string]any{"state": "busy"})
	if st := rosterStatus(t, e, t2, b2, a); st != nil {
		t.Fatalf("CONTROL: a status set in one workspace shows in the other: %v", st)
	}
	code, out := putStatus(t, e, t1, a, map[string]any{"state": "unavailable", "note": "On leave", "all_workspaces": true})
	if ws, _ := out["workspaces"].([]any); code != http.StatusOK || len(ws) != 2 {
		t.Fatalf("put all: %d %v", code, out)
	}
	for tid, viewer := range map[string]string{t1: b1, t2: b2} {
		if st := rosterStatus(t, e, tid, viewer, a); st["state"] != "unavailable" || st["note"] != "On leave" {
			t.Fatalf("%s: %v", tid, st)
		}
	}
	call(t, e, t1, http.MethodDelete, "/v1/me/status?all_workspaces=true", a, nil)
	for tid, viewer := range map[string]string{t1: b1, t2: b2} {
		if st := rosterStatus(t, e, tid, viewer, a); st != nil {
			t.Fatalf("%s after clear all: %v", tid, st)
		}
	}
}

func TestHumanStatusSearchField(t *testing.T) {
	e, _ := statusEnv(t)
	tid, _ := e.tenant()
	a := seat(t, e, tid, rbac.Developer)
	b := seat(t, e, tid, rbac.Developer)
	putStatus(t, e, tid, a, map[string]any{"state": "busy", "note": "In a meeting"})
	code, _, r, raw := searchGet(t, e, tid, a, "", memberHeader, b)
	if code != http.StatusOK {
		t.Fatalf("search: %d %v", code, raw)
	}
	for _, m := range r.Groups["users"].Results {
		if m["id"] == a {
			st, _ := m["status"].(map[string]any)
			if st["state"] != "busy" || st["note"] != "In a meeting" {
				t.Fatalf("search row: %v", m)
			}
			return
		}
	}
	t.Fatalf("search lists no %s: %v", a, raw)
}

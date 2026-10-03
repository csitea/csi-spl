package hub_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// rosterSeats reads GET /v1/view/roster's boxes[].seated_at, keyed box_id.
func rosterSeats(t *testing.T, e *env, tenant string) map[string]map[string]string {
	t.Helper()
	code, _, body := viewGet(t, e, tenant, "/v1/view/roster")
	var r struct {
		Boxes []struct {
			BoxID    string            `json:"box_id"`
			SeatedAt map[string]string `json:"seated_at"`
		} `json:"boxes"`
	}
	if err := json.Unmarshal(body, &r); err != nil || code != 200 {
		t.Fatalf("roster %d %s", code, body)
	}
	out := map[string]map[string]string{}
	for _, b := range r.Boxes {
		out[b.BoxID] = b.SeatedAt
	}
	return out
}

// Spec 061 3.6, lane L10 (rdb 0107): an id reused by a new holder leaves the
// box's roster (retire moves its spool dir) and enters it again. seated_at is
// that entry; an agent that stays announced keeps its stamp.
func TestViewRosterSeatedAtOnReuse(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
	tid, _ := e.tenant()
	a := e.box(tid, "box-a") // pin announces the spool dirs: none, so the test owns the roster
	e.pin(tid, a)
	ctx := context.Background()
	t0 := time.Date(2026, 10, 3, 9, 0, 0, 0, time.UTC)
	set := func(agents []string, at time.Time) {
		t.Helper()
		if err := e.st.SetRoster(ctx, tid, "box-a", agents, at); err != nil {
			t.Fatal(err)
		}
	}
	rfc := func(at time.Time) string { return at.UTC().Format(time.RFC3339Nano) }

	set([]string{"c-004"}, t0)
	if got := rosterSeats(t, e, tid)["box-a"]["c-004"]; got != rfc(t0) {
		t.Fatalf("first seat: c-004 seated_at %q, want %q", got, rfc(t0))
	}
	// Still announced (re-hello, a new agent next to it): the stamp stays.
	set([]string{"c-004", "c-005"}, t0.Add(time.Hour))
	s := rosterSeats(t, e, tid)["box-a"]
	if s["c-004"] != rfc(t0) || s["c-005"] != rfc(t0.Add(time.Hour)) {
		t.Fatalf("re-announce: %v, want c-004 %s kept and c-005 %s", s, rfc(t0), rfc(t0.Add(time.Hour)))
	}
	// Retired: gone from the roster, and from seated_at with it.
	set([]string{"c-005"}, t0.Add(2*time.Hour))
	if _, ok := rosterSeats(t, e, tid)["box-a"]["c-004"]; ok {
		t.Fatal("a retired id still reads a seated_at")
	}
	// Reused by the next holder past the quarantine: a new seat.
	reuse := t0.Add(26 * time.Hour)
	set([]string{"c-004", "c-005"}, reuse)
	s = rosterSeats(t, e, tid)["box-a"]
	if s["c-004"] != rfc(reuse) || s["c-005"] != rfc(t0.Add(time.Hour)) {
		t.Fatalf("reuse: %v, want c-004 %s and c-005 unchanged", s, rfc(reuse))
	}
}

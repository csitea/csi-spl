package hub_test

import (
	"context"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// rosterSpy records each list that reaches SetRoster, the one writer of both
// roster and agent_seats: an id never passed to it holds no row in either.
type rosterSpy struct {
	store.Store
	mu   sync.Mutex
	sets [][]string
}

func (s *rosterSpy) SetRoster(ctx context.Context, tenant, box string, agents []string, now time.Time) error {
	s.mu.Lock()
	s.sets = append(s.sets, append([]string(nil), agents...))
	s.mu.Unlock()
	return s.Store.SetRoster(ctx, tenant, box, agents, now)
}

// legacyWritten is the legacy ids SetRoster received since the last call.
func (s *rosterSpy) legacyWritten() []string {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []string
	for _, set := range s.sets {
		for _, a := range set {
			if agentid.IsLegacy(a) {
				out = append(out, a)
			}
		}
	}
	s.sets = nil
	return out
}

// legacyRosterEnv is a hub with one pinned box, the spy on its store and its
// log kept.
func legacyRosterEnv(t *testing.T) (*env, string, *box, *rosterSpy, *logBuf) {
	t.Helper()
	spy, l := &rosterSpy{}, &logBuf{}
	e := newEnv(t, func(o *hub.Options) {
		spy.Store = o.Store
		o.Store = spy
		o.Log = zerolog.New(l)
	})
	tid, _ := e.tenant()
	a := e.box(tid, "box-a")
	e.pin(tid, a)
	return e, tid, a, spy, l
}

// legacyRosterHello opens a role=box session announcing agents and waits for
// the welcome.
func legacyRosterHello(t *testing.T, e *env, tid string, b *box, agents ...string) *websocket.Conn {
	t.Helper()
	ctx := context.Background()
	c, n := e.raw(tid)
	t.Cleanup(func() { c.CloseNow() }) //nolint:errcheck
	h := helloFrame(b, n, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	h.Agents = agents
	wsjson.Write(ctx, c, h) //nolint:errcheck
	var w wire.Frame
	if err := wsjson.Read(ctx, c, &w); err != nil || w.Type != wire.TWelcome {
		t.Fatalf("welcome: %v %+v", err, w)
	}
	return c
}

func boxRoster(t *testing.T, e *env, tid string) string {
	t.Helper()
	r, err := e.st.Roster(context.Background(), tid)
	if err != nil {
		t.Fatal(err)
	}
	return strings.Join(r["box-a"], ",")
}

// Spec 061 FR-003, SPL-4926: past LegacyUntil a hello seats no legacy id. The
// box's good agents still are seated and the socket stays up: refusing the
// whole hello would take a box off the hub for one stale mailbox dir.
func TestHelloPastDeadlineDropsLegacyID(t *testing.T) {
	e, tid, a, spy, l := legacyRosterEnv(t)
	pinAgentClock(t, agentid.LegacyUntil.Add(time.Second))

	legacyRosterHello(t, e, tid, a, "c-004", "CLE-35034", "q-005", "HUM-9")

	if got := boxRoster(t, e, tid); got != "HUM-9,c-004,q-005" {
		t.Fatalf("roster past the deadline: %q", got)
	}
	if got := spy.legacyWritten(); len(got) != 0 {
		t.Fatalf("SetRoster received legacy ids past the deadline: %v", got)
	}
	if !strings.Contains(l.String(), `"agent":"CLE-35034"`) || !strings.Contains(l.String(), `"level":"warn"`) {
		t.Fatalf("no WARN naming the dropped id: %s", l.String())
	}
}

// The same on an announce, which also clears an id seated before the
// deadline and keeps the rest of the box: the validRoster trap.
func TestAnnouncePastDeadlineDropsLegacyID(t *testing.T) {
	e, tid, a, spy, l := legacyRosterEnv(t)
	pinAgentClock(t, agentid.LegacyUntil.Add(-time.Second))
	c := legacyRosterHello(t, e, tid, a, "c-004", "AGY-3499")
	// CONTROL: up to the deadline a legacy id is still seated, so what follows
	// proves the clock and not a blanket ban.
	if got := boxRoster(t, e, tid); got != "AGY-3499,c-004" {
		t.Fatalf("roster before the deadline: %q", got)
	}
	if got := spy.legacyWritten(); len(got) != 1 {
		t.Fatalf("SetRoster before the deadline: %v, want AGY-3499", got)
	}

	pinAgentClock(t, agentid.LegacyUntil.Add(time.Second))
	ctx := context.Background()
	wsjson.Write(ctx, c, wire.Frame{Type: wire.TAnnounce, Agents: []string{"c-004", "c-006", "AGY-3499", "GRK-1"}}) //nolint:errcheck
	want := "c-004,c-006"
	deadline := time.Now().Add(2 * time.Second)
	for boxRoster(t, e, tid) != want && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if got := boxRoster(t, e, tid); got != want {
		t.Fatalf("roster after the announce: %q, want %q", got, want)
	}
	if got := spy.legacyWritten(); len(got) != 0 {
		t.Fatalf("SetRoster received legacy ids past the deadline: %v", got)
	}
	for _, id := range []string{"AGY-3499", "GRK-1"} {
		if !strings.Contains(l.String(), `"agent":"`+id+`"`) {
			t.Fatalf("no WARN naming %s: %s", id, l.String())
		}
	}
	rctx, cancel := context.WithTimeout(ctx, 200*time.Millisecond)
	defer cancel()
	for {
		var f wire.Frame
		if err := wsjson.Read(rctx, c, &f); err != nil {
			return
		}
		if f.Type == wire.TError {
			t.Fatalf("the announce was refused: %+v", f)
		}
	}
}

// A duplicate stays the refusal it was: the drop must not run before
// validRoster and hide one.
func TestAnnouncePastDeadlineDuplicateStillRefused(t *testing.T) {
	e, tid, a, _, _ := legacyRosterEnv(t)
	pinAgentClock(t, agentid.LegacyUntil.Add(time.Second))
	c := legacyRosterHello(t, e, tid, a, "c-004")
	ctx := context.Background()
	wsjson.Write(ctx, c, wire.Frame{Type: wire.TAnnounce, Agents: []string{"c-004", "CLE-7", "CLE-7"}}) //nolint:errcheck
	rctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	for {
		var f wire.Frame
		if err := wsjson.Read(rctx, c, &f); err != nil {
			t.Fatalf("no refusal of a duplicate: %v", err)
		}
		if f.Type == wire.TError {
			if f.Error != "roster_duplicate" {
				t.Fatalf("refusal: %+v", f)
			}
			return
		}
	}
}

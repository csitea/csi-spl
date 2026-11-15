package hub_test

import (
	"context"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 147 5.1 (FR-004, FR-005): with claude capped at 1, a hello seats the
// first claude and the uncapped agents and drops the 2nd claude, the socket
// stays up; an announce adding a claude does the same (SPL-5642): only the
// capped claude stays out, the rest of the box's roster is seated.
func TestVendorCapAnnounceAndHello(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	tid, _ := e.tenant()
	a := e.box(tid, "box-a")
	e.pin(tid, a)
	one := 1
	if _, err := e.st.(store.AgentCapStore).SetAgentCaps(ctx, tid, map[string]*int{"claude": &one},
		store.AgentCapActor{Tenant: "ops", Hum: "HUM-1"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	roster := func() string {
		r, _ := e.st.Roster(ctx, tid)
		return strings.Join(r["box-a"], ",")
	}
	c, n := e.raw(tid)
	defer c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	h := helloFrame(a, n, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	h.Agents = []string{"c-004", "c-005", "q-004"}
	wsjson.Write(ctx, c, h) //nolint:errcheck
	var w wire.Frame
	if err := wsjson.Read(ctx, c, &w); err != nil || w.Type != wire.TWelcome {
		t.Fatalf("welcome: %v %+v", err, w)
	}
	if roster() != "c-004,q-004" {
		t.Fatalf("hello over the claude cap: roster %q, want c-004,q-004", roster())
	}
	// SPL-5642: an announce adding a claude over the cap AND an uncapped
	// agent seats the uncapped one and keeps only the claude out: no error
	// frame (one with no msg_id answered a send in flight), the box's roster
	// push comes back. Before the fix the whole replace was refused 409.
	wsjson.Write(ctx, c, wire.Frame{Type: wire.TAnnounce, Agents: []string{"c-004", "c-006", "q-004", "q-005"}}) //nolint:errcheck
	var f wire.Frame
	for f.Type != wire.TRoster {
		rctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		err := wsjson.Read(rctx, c, &f)
		cancel()
		if err != nil {
			t.Fatalf("no roster push for an announce over the cap: %v", err)
		}
		if f.Type == wire.TError {
			t.Fatalf("announce over the cap answered an error frame: %+v", f)
		}
	}
	if got := strings.Join(f.Roster["box-a"], ","); got != "c-004,q-004,q-005" {
		t.Fatalf("announce over the claude cap: pushed roster %q, want c-004,q-004,q-005", got)
	}
	if roster() != "c-004,q-004,q-005" {
		t.Fatalf("announce over the claude cap: roster %q, want c-004,q-004,q-005", roster())
	}
}

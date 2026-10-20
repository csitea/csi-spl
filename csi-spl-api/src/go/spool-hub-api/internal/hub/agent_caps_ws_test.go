package hub_test

import (
	"context"
	"net/http"
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
// stays up; an announce adding a claude is 409 vendor_cap_exceeded naming
// vendor, cap and count, and the roster stands.
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
	// CONTROL: an announce adding a claude is refused, the roster stands.
	wsjson.Write(ctx, c, wire.Frame{Type: wire.TAnnounce, Agents: []string{"c-004", "c-006", "q-004"}}) //nolint:errcheck
	var f wire.Frame
	for f.Type != wire.TError {
		rctx, cancel := context.WithTimeout(ctx, 2*time.Second)
		err := wsjson.Read(rctx, c, &f)
		cancel()
		if err != nil {
			t.Fatalf("no error frame for an announce over the cap: %v", err)
		}
	}
	if f.Error != "vendor_cap_exceeded" || f.Status != http.StatusConflict ||
		!strings.Contains(f.Detail, "claude agent cap reached for workspace "+tid+": max 1 live, requested 2 live") {
		t.Fatalf("announce over the cap: %+v", f)
	}
	if roster() != "c-004,q-004" {
		t.Fatalf("refused announce changed the roster: %q", roster())
	}
	// An uncapped addition is admitted.
	wsjson.Write(ctx, c, wire.Frame{Type: wire.TAnnounce, Agents: []string{"c-004", "q-004", "q-005"}}) //nolint:errcheck
	deadline := time.Now().Add(2 * time.Second)
	for roster() != "c-004,q-004,q-005" && time.Now().Before(deadline) {
		time.Sleep(20 * time.Millisecond)
	}
	if roster() != "c-004,q-004,q-005" {
		t.Fatalf("uncapped addition: %q", roster())
	}
}

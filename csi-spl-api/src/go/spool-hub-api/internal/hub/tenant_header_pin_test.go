package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 108 section 4, pair (b), n=2: header / pin mismatch. A box holds a
// valid pin in workspace A. On the api host it names its workspace with
// X-Spool-Tenant; naming workspace B with that same valid key is refused,
// at the socket hello and with the upload token it holds. CONTROL: the
// matching header (A) is accepted on both, so a refusal means "wrong
// workspace", not "the box cannot get in at all".
//
// Workspace B also pins a box with the SAME box id under another key, so
// the refusal cannot come from "no such box in B": the box id exists in B,
// only the key that box-a signs with is A's.

// TestTenantHeaderPinMismatchRefused is pair (b), n=2.
func TestTenantHeaderPinMismatchRefused(t *testing.T) {
	e := newEnv(t)
	a, _ := e.tenant()
	b, _ := e.tenant()
	bx := e.box(a, "box-a", "AGENT-A")
	e.pin(a, bx)
	other := e.box(b, "box-a", "AGENT-B") // same box id, its own key, pinned in B
	e.pin(b, other)
	ctx := context.Background()

	// hello dials the api host naming tenant and says hello as bx.
	hello := func(tenant string) (wire.Frame, error) {
		t.Helper()
		c, code := e.dialWS(apiLabel, "/v1/ws", http.Header{hub.TenantHeader: {tenant}})
		if c == nil {
			t.Fatalf("dial naming %s: %d", tenant, code)
		}
		defer c.CloseNow() //nolint:errcheck
		var ch wire.Frame
		if err := wsjson.Read(ctx, c, &ch); err != nil || ch.Type != wire.TChallenge {
			t.Fatalf("challenge naming %s: %v %+v", tenant, err, ch)
		}
		if err := wsjson.Write(ctx, c, helloFrame(bx, ch.Nonce, time.Now().UTC().Format(time.RFC3339), wire.RoleCLI)); err != nil {
			t.Fatal(err)
		}
		var f wire.Frame
		return f, wsjson.Read(ctx, c, &f)
	}

	// CONTROL: the matching header is accepted, and hands out a token.
	wel, err := hello(a)
	if err != nil || wel.Type != wire.TWelcome || wel.UploadToken == "" {
		t.Fatalf("control: hello naming the pinned workspace A: %v %+v", err, wel)
	}
	// PAIR: the same valid key naming B is refused at hello.
	if f, err := hello(b); err == nil {
		t.Fatalf("hello naming workspace B with A's pin was accepted: %+v", f)
	} else if code := websocket.CloseStatus(err); code != wire.CloseUnauthorized {
		t.Fatalf("hello naming workspace B: close %d (%v), want %d", code, err, wire.CloseUnauthorized)
	}

	// The upload token A's hello minted, on the api host.
	pins := func(tenant string) int {
		t.Helper()
		rq, _ := http.NewRequest(http.MethodGet, "http://"+apiLabel+domain+"/v1/pins", nil)
		rq.Header.Set("Authorization", "Bearer "+wel.UploadToken)
		rq.Header.Set(hub.TenantHeader, tenant)
		resp, err := e.client.Do(rq)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	// CONTROL: the token with the matching header reads A's pins.
	if c := pins(a); c != http.StatusOK {
		t.Fatalf("control: A's token naming A: %d, want 200", c)
	}
	// PAIR: the same token naming B is refused.
	if c := pins(b); c != http.StatusForbidden {
		t.Fatalf("A's token naming workspace B: %d, want 403", c)
	}

	// B's own box (same id, B's key) still gets into B: the refusal above
	// was A's key in B, not B being closed.
	if s, err := other.c.Dial(ctx, wire.RoleCLI); err != nil {
		t.Fatalf("control: B's own box-a into B: %v", err)
	} else {
		s.Close()
	}
}

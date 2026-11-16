package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// ---- hello --------------------------------------------------------------------

func TestHelloNonceAcceptAndReplayReject(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)
	now := time.Now().UTC().Format(time.RFC3339)

	// Accept: the right nonce, fresh ts, pinned box.
	c1, n1 := e.raw(tid)
	hello := helloFrame(a, n1, now, wire.RoleCLI)
	wsjson.Write(context.Background(), c1, hello) //nolint:errcheck
	var wel wire.Frame
	if err := wsjson.Read(context.Background(), c1, &wel); err != nil || wel.Type != wire.TWelcome || wel.UploadToken == "" {
		t.Fatalf("welcome: %v %+v", err, wel)
	}
	c1.Close(websocket.StatusNormalClosure, "") //nolint:errcheck

	// Replay: the captured hello on a new socket (new nonce) is refused.
	c2, n2 := e.raw(tid)
	if n2 == n1 {
		t.Fatal("nonce reused across sockets")
	}
	wsjson.Write(context.Background(), c2, hello) //nolint:errcheck
	if code, why := closeReason(t, c2); code != wire.CloseUnauthorized || why != "bad_nonce" {
		t.Fatalf("replay: %d %q", code, why)
	}

	// Stale ts (outside ±300 s).
	c3, n3 := e.raw(tid)
	wsjson.Write(context.Background(), c3, helloFrame(a, n3, time.Now().Add(-10*time.Minute).UTC().Format(time.RFC3339), wire.RoleCLI)) //nolint:errcheck
	if code, why := closeReason(t, c3); code != wire.CloseUnauthorized || why != "stale_hello" {
		t.Fatalf("stale: %d %q", code, why)
	}

	// Unpinned box; nothing stored for it.
	u := e.box(tid, "box-u")
	c4, n4 := e.raw(tid)
	wsjson.Write(context.Background(), c4, helloFrame(u, n4, now, wire.RoleBox)) //nolint:errcheck
	if code, why := closeReason(t, c4); code != wire.CloseUnauthorized || why != "unpinned_box" {
		t.Fatalf("unpinned: %d %q", code, why)
	}
	if r, _ := e.st.Roster(context.Background(), tid); len(r["box-u"]) != 0 {
		t.Fatal("unpinned box's roster was stored")
	}

	// Bad sig: box-a's hello signed by another key.
	c5, n5 := e.raw(tid)
	bad := helloFrame(u, n5, now, wire.RoleCLI)
	bad.BoxID = "box-a"
	wsjson.Write(context.Background(), c5, bad) //nolint:errcheck
	if code, why := closeReason(t, c5); code != wire.CloseUnauthorized || why != "bad_sig" {
		t.Fatalf("bad sig: %d %q", code, why)
	}

	// No hello at all → 4408.
	c6, _ := e.raw(tid)
	if code, why := closeReason(t, c6); code != wire.CloseHelloTimeout || why != "hello_timeout" {
		t.Fatalf("timeout: %d %q", code, why)
	}

	// Unknown tenant → HTTP 404 before any upgrade.
	resp, err := e.client.Get("http://nope" + domain + "/v1/ws")
	if err != nil || resp.StatusCode != http.StatusNotFound {
		t.Fatalf("unknown tenant: %v %v", err, resp)
	}
}

func TestLastHelloWinsOnlyForBoxRole(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, a)
	ctx := context.Background()

	s1, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	cli, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(cli)
	select {
	case <-s1.Done():
		t.Fatal("a role=cli hello evicted the box session")
	case <-time.After(200 * time.Millisecond):
	}
	s2, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(s2)
	select {
	case <-s1.Done():
		if s1.CloseCode() != wire.CloseSuperseded {
			t.Fatalf("old session closed with %d, want 4409", s1.CloseCode())
		}
	case <-time.After(3 * time.Second):
		t.Fatal("old role=box session not evicted")
	}
}

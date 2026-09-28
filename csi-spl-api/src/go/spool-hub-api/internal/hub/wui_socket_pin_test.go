package hub_test

import (
	"context"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Pins of the browser socket's hello and frame refusals no other test drove,
// taken before handleWUIWS was split into named steps (SPL-1029 round 2).

func wuiRaw(t *testing.T, e *env, tenant, member string) *websocket.Conn {
	t.Helper()
	h := http.Header{}
	if member != "" {
		h.Set(memberHeader, member)
	}
	c, _, err := websocket.Dial(context.Background(), "ws://"+tenant+domain+"/v1/wui/ws", &websocket.DialOptions{HTTPClient: e.client, HTTPHeader: h})
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	t.Cleanup(func() { c.CloseNow() }) //nolint:errcheck
	return c
}

func wuiClose(t *testing.T, c *websocket.Conn) (websocket.StatusCode, string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		var f map[string]any
		err := wsjson.Read(ctx, c, &f)
		var ce websocket.CloseError
		if errors.As(err, &ce) {
			return ce.Code, ce.Reason
		}
		if err != nil {
			t.Fatalf("want a close, got %v", err)
		}
	}
}

func TestWUIHelloRefusals(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	for _, c := range []struct {
		name  string
		hello map[string]string
	}{
		{"not a hello", map[string]string{"type": "send", "as": "Tess"}},
		{"as over 64 bytes", map[string]string{"type": "hello", "as": strings.Repeat("x", 65)}},
	} {
		conn := wuiRaw(t, e, tid, "HUM-1")
		wsjson.Write(context.Background(), conn, c.hello) //nolint:errcheck
		if code, why := wuiClose(t, conn); code != wire.CloseBadFrame || why != "bad_frame" {
			t.Errorf("%s: %d %q", c.name, code, why)
		}
	}
}

func TestWUIFrameRefusals(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	c := dialMember(t, e, tid, "Tess", "HUM-1")
	for _, tc := range []struct {
		frame map[string]any
		token string
	}{
		{map[string]any{"type": "subscribe", "task_id": "not-a-uuid"}, "bad_frame"},
		{map[string]any{"type": "unsubscribe", "task_id": "nope"}, "bad_frame"},
		{map[string]any{"type": "frobnicate"}, "bad_frame"},
	} {
		wsjson.Write(context.Background(), c, tc.frame) //nolint:errcheck
		if f := readType(t, c, "error"); f["error"] != tc.token || f["status"] != float64(400) {
			t.Errorf("%v: %v", tc.frame, f)
		}
	}
	wsjson.Write(context.Background(), c, map[string]any{"type": "token"}) //nolint:errcheck
	if f := readType(t, c, "token"); f["upload_token"] == "" || f["upload_token_expires_at"] == "" {
		t.Errorf("token: %v", f)
	}
	// a hub without a lobby refuses the lobby alias
	n := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) { return r.Header.Get(memberHeader), nil }
	})
	nt, _ := n.tenant()
	nc := dialMember(t, n, nt, "Tess", "HUM-1")
	wsjson.Write(context.Background(), nc, map[string]any{"type": "subscribe", "task_id": "LOBBY"}) //nolint:errcheck
	if f := readType(t, nc, "error"); f["error"] != "lobby_disabled" {
		t.Errorf("lobby alias without a lobby: %v", f)
	}
}

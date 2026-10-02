package hub_test

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// spec 062 (contracts/flow-v1.md): GET /v1/view/flow and the live `flow`
// frame. HUM-2 mentions HUM-1 in #lobby: HUM-1's socket gets a frame with the
// event and counts, the route lists it; HUM-1 opens the pane (f:seen) and
// every socket of HUM-1 gets the badge back to 0 while the chips keep 1.

// dialFlowMember is a browser socket signed in as member (followEnv's session seam).
func dialFlowMember(t *testing.T, e *env, tid, member string) *websocket.Conn {
	t.Helper()
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, "ws://"+tid+domain+"/v1/wui/ws", &websocket.DialOptions{
		HTTPClient: e.client, HTTPHeader: http.Header{memberHeader: {member}}})
	if err != nil {
		t.Fatalf("dial %s: %v", member, err)
	}
	t.Cleanup(func() { c.CloseNow() })                                     //nolint:errcheck
	wsjson.Write(ctx, c, map[string]string{"type": "hello", "as": member}) //nolint:errcheck
	readFrame(t, c, "welcome")
	return c
}

// readFrame is the next frame of type want, skipping others.
func readFrame(t *testing.T, c *websocket.Conn, want string) map[string]any {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		var f map[string]any
		if err := wsjson.Read(ctx, c, &f); err != nil {
			t.Fatalf("waiting for %s: %v", want, err)
		}
		if f["type"] == want {
			return f
		}
	}
}

func countOf(f map[string]any, field, kind string) float64 {
	m, _ := f[field].(map[string]any)
	n, _ := m[kind].(float64)
	return n
}

func TestFlowRouteAndFrames(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	one, two := dialFlowMember(t, e, tid, "HUM-1"), dialFlowMember(t, e, tid, "HUM-2")
	oneB := dialFlowMember(t, e, tid, "HUM-1") // HUM-1's second device

	wsjson.Write(context.Background(), two, map[string]any{"type": "send", "task_id": "lobby", "kind": "chat", "body": "hey @HUM-1 look"}) //nolint:errcheck
	readFrame(t, two, "ack")
	f := readFrame(t, one, "flow")
	ev, _ := f["event"].(map[string]any)
	if ev["kind"] != "mention" || ev["from"] != "HUM-2" || ev["text"] != "hey @HUM-1 look" || ev["unread"] != true || ev["channel"] != "lobby" {
		t.Fatalf("flow frame event = %v", ev)
	}
	if _, ok := ev["env"]; ok {
		t.Fatal("a flow entry carries the envelope")
	}
	if countOf(f, "counts", "mention") != 1 || countOf(f, "counts", "total") != 1 || countOf(f, "unread", "total") != 1 {
		t.Fatalf("flow frame counts = %v / %v", f["counts"], f["unread"])
	}
	readFrame(t, oneB, "flow")

	code, out := call(t, e, tid, http.MethodGet, "/v1/view/flow", "HUM-1", nil)
	events, _ := out["events"].([]any)
	if code != http.StatusOK || len(events) != 1 || out["next"] != "" || countOf(out, "counts", "total") != 1 {
		t.Fatalf("GET /v1/view/flow: %d %v", code, out)
	}
	msgID, _ := events[0].(map[string]any)["msg_id"].(string)
	if code, out := call(t, e, tid, http.MethodGet, "/v1/view/flow", "HUM-2", nil); code != http.StatusOK || len(out["events"].([]any)) != 0 {
		t.Fatalf("CONTROL: the author has no event of their own line: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodGet, "/v1/view/flow?counts_only=true", "HUM-1", nil); code != http.StatusOK || out["events"] != nil || countOf(out, "unread", "mention") != 1 {
		t.Fatalf("counts_only: %d %v", code, out)
	}
	for _, q := range []string{"?limit=0", "?limit=51", "?kind=poke", "?before=nope"} {
		if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/flow"+q, "HUM-1", nil); code != http.StatusBadRequest {
			t.Errorf("GET /v1/view/flow%s: %d, want 400", q, code)
		}
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/flow", "", nil); code != http.StatusForbidden {
		t.Errorf("no member session: %d, want 403", code)
	}

	// Opening the pane on one device moves the badge on both.
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if code, out := call(t, e, tid, http.MethodPut, "/v1/me/reads", "HUM-1", map[string]any{"marks": map[string]any{"f:seen": map[string]any{"ts": now}}}); code != http.StatusOK {
		t.Fatalf("PUT f:seen: %d %v", code, out)
	}
	for _, c := range []*websocket.Conn{one, oneB} {
		f := readFrame(t, c, "flow")
		if f["event"] != nil || countOf(f, "counts", "total") != 0 || countOf(f, "unread", "total") != 1 {
			t.Fatalf("after f:seen frame = %v", f)
		}
	}
	// Opening the entry clears the chip too.
	if code, out := call(t, e, tid, http.MethodPut, "/v1/me/reads", "HUM-1", map[string]any{"marks": map[string]any{"f:" + msgID: map[string]any{"ts": now}}}); code != http.StatusOK {
		t.Fatalf("PUT f:<msg_id>: %d %v", code, out)
	}
	if f := readFrame(t, one, "flow"); countOf(f, "unread", "total") != 0 {
		t.Fatalf("after f:<msg_id> frame = %v", f)
	}
	for _, k := range []string{"f:nope", "f:" + msgID + "x", "f:"} {
		if code, _ := call(t, e, tid, http.MethodPut, "/v1/me/reads", "HUM-1", map[string]any{"marks": map[string]any{k: map[string]any{"ts": now}}}); code != http.StatusBadRequest {
			t.Errorf("PUT %s: %d, want 400", k, code)
		}
	}
}

// FR-007 across hub processes: with the WUI wake-up on, the mark write is
// announced by the store and the wake worker pushes the frame.
func TestFlowMarkFrameThroughWake(t *testing.T) {
	a := newEnv(t, func(o *hub.Options) {
		o.ViewDoor, o.LobbyTaskID, o.ViewCORSOrigins, o.WakeWUI = hub.ViewDoorOff, lobby, []string{wuiOrigin}, true
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
	})
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go a.srv.RunWake(ctx)
	time.Sleep(300 * time.Millisecond) // the listener is up before the write
	tid, _ := a.tenant()
	c := dialFlowMember(t, a, tid, "HUM-1")
	now := time.Now().UTC().Format(time.RFC3339Nano)
	if code, out := call(t, a, tid, http.MethodPut, "/v1/me/reads", "HUM-1", map[string]any{"marks": map[string]any{"f:seen": map[string]any{"ts": now}}}); code != http.StatusOK {
		t.Fatalf("PUT f:seen: %d %v", code, out)
	}
	if f := readFrame(t, c, "flow"); f["event"] != nil || countOf(f, "counts", "total") != 0 {
		t.Fatalf("frame through the wake worker = %v", f)
	}
}

package hub_test

import (
	"context"
	"encoding/json"
	"slices"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
)

// presenceOf is lane_op box_presence_get through c (a one-shot role=cli
// session signed by the box's own key, as `spool box-presence` sends it).
func presenceOf(t *testing.T, c *hubclient.Client) (socket bool, box string, agents []string) {
	t.Helper()
	raw, err := c.Lane(context.Background(), "box_presence_get", "", nil)
	if err != nil {
		t.Fatalf("box_presence_get: %v", err)
	}
	var out struct {
		Box    string   `json:"box"`
		Socket *bool    `json:"socket"`
		Agents []string `json:"agents"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || out.Socket == nil || out.Agents == nil {
		t.Fatalf("box_presence_get answer %s: %v", raw, err)
	}
	return *out.Socket, out.Box, out.Agents
}

// SPL-5318 (spec 069 8.4): the desk move proves a moved desk live with the
// desk's own key, no member login. The probe's own cli hello re-stamps
// boxes.last_hello_at, so the roster's online flag reads the box online with
// no sidecar at all: that is the red this op exists for. box_presence_get
// answers from a role=box socket on the answering instance only.
func TestBoxPresenceGetIsTheSocketNotTheStamp(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "c-004")
	other := e.box(tid, "box-o", "c-005")
	e.pin(tid, a)
	e.pin(tid, other)
	connectBox(t, e, tid, other, "c-005") // another box's socket never counts for a

	// No sidecar for box-a: the cli probe says no socket ...
	on, box, agents := presenceOf(t, a.c)
	if on || box != "box-a" {
		t.Fatalf("box-a has no role=box socket: socket=%v box=%q", on, box)
	}
	// ... while the roster's online, read right after that same cli hello,
	// says online: the self-fulfilling proof the old path would take.
	if r := rosterOnline(t, e, tid); !r["box-a"] {
		t.Fatalf("the roster should read cli-only box-a online (the stamp): %v", r)
	}

	// The sidecar connects: socket true, its seated agents.
	c := connectBox(t, e, tid, a, "c-004")
	on, _, agents = presenceOf(t, a.c)
	if !on || !slices.Equal(agents, []string{"c-004"}) {
		t.Fatalf("box-a with its sidecar up: socket=%v agents=%v", on, agents)
	}

	// Another instance does not hold the socket: false there (per instance,
	// the caller retries), never true from the shared stamp.
	peer := newPeer(t, e, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
	pc := hubclient.New(a.cfg)
	pc.HTTP = peer.client
	pc.ReadyTimeout = 5 * time.Second
	if on, _, agents = presenceOf(t, pc); on || !slices.Equal(agents, []string{"c-004"}) {
		t.Fatalf("instance B without box-a's socket: socket=%v agents=%v", on, agents)
	}

	// The sidecar goes away: socket false again, at once.
	c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	deadline := time.Now().Add(3 * time.Second)
	for on = true; on && time.Now().Before(deadline); time.Sleep(20 * time.Millisecond) {
		on, _, _ = presenceOf(t, a.c)
	}
	if on {
		t.Fatalf("box-a's sidecar closed, box_presence_get still says socket true")
	}
}

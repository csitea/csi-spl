package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// helloRun says a role=box hello carrying the agent run report and waits
// for the welcome (helloHost, plus AgentRun).
func helloRun(t *testing.T, e *env, tenant string, b *box, run map[string]bool, agents ...string) *rawBox {
	t.Helper()
	c, n := e.raw(tenant)
	h := helloFrame(b, n, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	h.Agents, h.AgentRun = agents, run
	wsjson.Write(context.Background(), c, h) //nolint:errcheck
	r := &rawBox{t: t, c: c}
	r.next(wire.TWelcome)
	r.next(wire.TQueueEnd)
	t.Cleanup(func() { c.CloseNow() }) //nolint:errcheck
	return r
}

// states is each roster agent's agent_presence state of one box.
func states(t *testing.T, e *env, tenant, box string) map[string]string {
	t.Helper()
	out := map[string]string{}
	for id, p := range rosterBoxes(t, e, tenant)[box].AgentPresence {
		out[id] = p.State
	}
	return out
}

func wantStates(t *testing.T, what string, got, want map[string]string) {
	t.Helper()
	if len(got) != len(want) {
		t.Fatalf("%s: agent_presence = %v, want %v", what, got, want)
	}
	for id, s := range want {
		if got[id] != s {
			t.Fatalf("%s: agent_presence = %v, want %v", what, got, want)
		}
	}
}

// t1 bc1a43e1 (fix A): c-001@<box> read green while that box's desk was up and no
// c-001 ran on it. An online box's agent that the box reports as not running
// reads "not_running"; one it reports running, or does not report, reads
// "online"; an older box (no report) keeps today's behaviour; an id the box
// does not announce is never stored. CONTROL: on the pre-fix hub every
// agent of an online box read "online", so the first check fails there.
func TestAgentRunPresence(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "c-001", "c-002", "c-003")
	old := e.box(tid, "box-o", "c-004")
	e.pin(tid, a)
	e.pin(tid, old)

	rb := helloRun(t, e, tid, a, map[string]bool{"c-001": true, "c-002": false, "c-009": false}, "c-001", "c-002", "c-003")
	connectBox(t, e, tid, old, "c-004") // an older box: no report
	wantStates(t, "hello", states(t, e, tid, "box-a"),
		map[string]string{"c-001": "online", "c-002": "not_running", "c-003": "online"})
	wantStates(t, "older box", states(t, e, tid, "box-o"), map[string]string{"c-004": "online"})
	if !rosterBoxes(t, e, tid)["box-a"].Online {
		t.Fatal("box-a must stay online: only its agent is not running")
	}

	// The box's next report flips them: the announce replaces the old one.
	wsjson.Write(context.Background(), rb.c, wire.Frame{Type: wire.TAnnounce, //nolint:errcheck
		Agents: []string{"c-001", "c-002", "c-003"}, AgentRun: map[string]bool{"c-001": false, "c-002": true, "c-003": false}})
	waitStates(t, e, tid, "announce", map[string]string{"c-001": "not_running", "c-002": "online", "c-003": "not_running"})

	// An announce without a report (a stale one, an older binary): today's behaviour.
	wsjson.Write(context.Background(), rb.c, wire.Frame{Type: wire.TAnnounce, Agents: []string{"c-001", "c-002", "c-003"}}) //nolint:errcheck
	waitStates(t, e, tid, "unreported", map[string]string{"c-001": "online", "c-002": "online", "c-003": "online"})

	// The box gone: every agent reads offline, whatever it last reported.
	wsjson.Write(context.Background(), rb.c, wire.Frame{Type: wire.TAnnounce, //nolint:errcheck
		Agents: []string{"c-001", "c-002", "c-003"}, AgentRun: map[string]bool{"c-001": false}})
	waitStates(t, e, tid, "re-report", map[string]string{"c-001": "not_running", "c-002": "online", "c-003": "online"})
	rb.c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	waitStates(t, e, tid, "box gone", map[string]string{"c-001": "offline", "c-002": "offline", "c-003": "offline"})
}

// waitStates polls box-a's agent_presence until it is want (an announce is
// applied on the box's read goroutine, after the write returns).
func waitStates(t *testing.T, e *env, tenant, what string, want map[string]string) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		got := states(t, e, tenant, "box-a")
		same := len(got) == len(want)
		for id, s := range want {
			same = same && got[id] == s
		}
		if same {
			return
		}
		if time.Now().After(deadline) {
			wantStates(t, what, got, want)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// The browser's presence frames follow the report: an agent its box says
// does not run is announced "not_running", never "online", on hello, on the
// snapshot a new browser gets and on an announce that flips it.
func TestAgentRunPresenceFrames(t *testing.T) {
	e := wuiEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "GRK-03", "GRK-04")
	e.pin(tid, a)
	w := dialWUI(t, e, tid, "HUM-1")

	rb := helloRun(t, e, tid, a, map[string]bool{"GRK-03": false, "GRK-04": true}, "GRK-03", "GRK-04")
	w.presence("GRK-04@box-a", "online") // online first, then not_running
	w.presence("GRK-03@box-a", "not_running")

	// A second browser's snapshot names GRK-04 online and never GRK-03.
	v := dialWUI(t, e, tid, "HUM-2")
	v.presence("GRK-04@box-a", "online")
	ctx, cancel := context.WithTimeout(context.Background(), 300*time.Millisecond)
	for {
		var f presence
		if err := wsjson.Read(ctx, v.c, &f); err != nil {
			break
		}
		if f.Type == "presence" && f.Peer == "GRK-03@box-a" && f.Status == "online" {
			cancel()
			t.Fatalf("snapshot says a not-running agent is online: %+v", f)
		}
	}
	cancel()

	// GRK-03 starts, GRK-04 stops.
	wsjson.Write(context.Background(), rb.c, wire.Frame{Type: wire.TAnnounce, //nolint:errcheck
		Agents: []string{"GRK-03", "GRK-04"}, AgentRun: map[string]bool{"GRK-03": true, "GRK-04": false}})
	w.presence("GRK-03@box-a", "online")
	w.presence("GRK-04@box-a", "not_running")
}

// The real box client: its hello and its announce carry the report its
// AgentRun func gives (cmd/spool wires the fleet tick's file into it).
func TestHubclientAgentRun(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "c-001", "c-002")
	e.pin(tid, a)
	running := map[string]bool{"c-001": true, "c-002": false}
	a.c.AgentRun = func(agents []string) map[string]bool {
		out := map[string]bool{}
		for _, id := range agents {
			out[id] = running[id]
		}
		return out
	}
	sess, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sess)
	waitStates(t, e, tid, "client hello", map[string]string{"c-001": "online", "c-002": "not_running"})

	running = map[string]bool{"c-001": false, "c-002": true}
	if err := sess.Announce(ctx); err != nil {
		t.Fatal(err)
	}
	waitStates(t, e, tid, "client announce", map[string]string{"c-001": "not_running", "c-002": "online"})
}

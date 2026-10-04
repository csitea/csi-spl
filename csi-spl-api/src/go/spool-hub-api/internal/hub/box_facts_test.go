package hub_test

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// rosterBox is one boxes[] row of GET /v1/view/roster, the fields the Boxes
// page reads (t1 f77c9f87).
type rosterBox struct {
	BoxID         string            `json:"box_id"`
	Online        bool              `json:"online"`
	LastHelloAt   *string           `json:"last_hello_at"`
	OS            *wire.HostOS      `json:"os"`
	Runtimes      map[string]string `json:"runtimes"`
	AgentPresence map[string]struct {
		State    string  `json:"state"`
		LastSeen *string `json:"last_seen"`
	} `json:"agent_presence"`
}

func rosterBoxes(t *testing.T, e *env, tenant string) map[string]rosterBox {
	t.Helper()
	code, _, body := viewGet(t, e, tenant, "/v1/view/roster")
	var r struct {
		Boxes []rosterBox `json:"boxes"`
	}
	if err := json.Unmarshal(body, &r); err != nil || code != 200 {
		t.Fatalf("roster %d %s", code, body)
	}
	out := map[string]rosterBox{}
	for _, b := range r.Boxes {
		out[b.BoxID] = b
	}
	return out
}

// helloHost says a role=box hello carrying host and waits for the welcome.
func helloHost(t *testing.T, e *env, tenant string, b *box, host *wire.BoxHost, agents ...string) *websocket.Conn {
	t.Helper()
	ctx := context.Background()
	c, n := e.raw(tenant)
	h := helloFrame(b, n, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	h.Agents, h.Host = agents, host
	wsjson.Write(ctx, c, h) //nolint:errcheck
	var wel wire.Frame
	if err := wsjson.Read(ctx, c, &wel); err != nil || wel.Type != wire.TWelcome {
		t.Fatalf("welcome %v %+v", err, wel)
	}
	go func() {
		for {
			if _, _, err := c.Read(ctx); err != nil {
				return
			}
		}
	}()
	t.Cleanup(func() { c.CloseNow() }) //nolint:errcheck
	return c
}

// The hello's host report is served as boxes[].os and boxes[].runtimes, and
// every roster agent carries its presence; a box that said none has none.
func TestBoxFactsOnRoster(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "c-001")
	old := e.box(tid, "box-o", "c-002")
	e.pin(tid, a)
	e.pin(tid, old)
	host := &wire.BoxHost{
		OS:       &wire.HostOS{Name: "Debian GNU/Linux", Version: "13", Kernel: "6.12.111+deb13-cloud-amd64", Arch: "amd64"},
		Runtimes: map[string]string{"go": "1.25.1", "node": "22.1.0", "claude": "2.1.3"},
	}
	c := helloHost(t, e, tid, a, host, "c-001")
	connectBox(t, e, tid, old, "c-002") // an older box: no host

	rs := rosterBoxes(t, e, tid)
	got := rs["box-a"]
	if got.OS == nil || *got.OS != *host.OS {
		t.Fatalf("os = %+v, want %+v", got.OS, host.OS)
	}
	if fmt.Sprint(got.Runtimes) != fmt.Sprint(host.Runtimes) {
		t.Fatalf("runtimes = %v, want %v", got.Runtimes, host.Runtimes)
	}
	p, ok := got.AgentPresence["c-001"]
	if !ok || p.State != "online" || p.LastSeen == nil || got.LastHelloAt == nil || *p.LastSeen != *got.LastHelloAt {
		t.Fatalf("agent_presence = %+v (last_hello_at %v)", got.AgentPresence, got.LastHelloAt)
	}
	if o := rs["box-o"]; o.OS != nil || o.Runtimes != nil {
		t.Fatalf("a box that said no host reads one: %+v", o)
	}

	// Gone: its agents read offline, last seen kept; the facts stay (static).
	c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	deadline := time.Now().Add(2 * time.Second)
	for rosterBoxes(t, e, tid)["box-a"].Online {
		if time.Now().After(deadline) {
			t.Fatal("box-a still online after its socket closed")
		}
		time.Sleep(10 * time.Millisecond)
	}
	got = rosterBoxes(t, e, tid)["box-a"]
	if p := got.AgentPresence["c-001"]; p.State != "offline" || p.LastSeen == nil {
		t.Fatalf("offline agent_presence = %+v", p)
	}
	if got.OS == nil {
		t.Fatal("facts dropped on disconnect")
	}

	// Last hello wins: a redial without host (a downgraded binary) clears them.
	connectBox(t, e, tid, a, "c-001")
	if got := rosterBoxes(t, e, tid)["box-a"]; got.OS != nil || got.Runtimes != nil {
		t.Fatalf("a hello without host left the old facts: %+v", got)
	}
}

// The host report is untrusted: an oversized or hostile field is cut, never
// stored as sent, and never costs the box its hello.
func TestBoxFactsHostileCut(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "c-001")
	e.pin(tid, a)
	rt := map[string]string{
		"Bad Key":                "1.0",                       // not a slug: dropped
		"<script>":               "1.0",                       // dropped
		"empty":                  "\x00\x1b[31m",              // nothing printable left: dropped
		"node":                   "22.1.0\x1b[2J‮\n",          // escape, bidi, newline stripped
		"docker":                 strings.Repeat("9", 10_000), // cut
		strings.Repeat("k", 300): "1.0",                       // name too long: dropped
	}
	for i := range 100 {
		rt[fmt.Sprintf("rt%03d", i)] = "1.0"
	}
	host := &wire.BoxHost{OS: &wire.HostOS{
		Name:    strings.Repeat("A", 100_000),
		Version: "13\u0000",
		Kernel:  "‮6.12",
		Arch:    "\x1b]0;pwned\x07",
	}, Runtimes: rt}
	helloHost(t, e, tid, a, host, "c-001")

	got := rosterBoxes(t, e, tid)["box-a"]
	if !got.Online {
		t.Fatal("a hostile host report cost the box its hello")
	}
	if got.OS == nil || len(got.OS.Name) != 64 || got.OS.Version != "13" || got.OS.Kernel != "6.12" || got.OS.Arch != "]0;pwned" {
		t.Fatalf("os not cut: %+v", got.OS)
	}
	if len(got.Runtimes) != 16 {
		t.Fatalf("runtimes = %d entries, want the cap 16: %v", len(got.Runtimes), got.Runtimes)
	}
	if got.Runtimes["node"] != "22.1.0[2J" || len(got.Runtimes["docker"]) != 64 {
		t.Fatalf("runtime values not cleaned: node=%q docker=%d", got.Runtimes["node"], len(got.Runtimes["docker"]))
	}
	for k, v := range got.Runtimes {
		if strings.ContainsAny(k, " <>") || len(k) > 24 || v == "" {
			t.Fatalf("bad runtime kept: %q=%q", k, v)
		}
	}
}

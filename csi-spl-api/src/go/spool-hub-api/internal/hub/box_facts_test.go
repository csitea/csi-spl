package hub_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// rosterBox is one boxes[] row of GET /v1/view/roster, the fields the Boxes
// page reads (t1 f77c9f87).
type rosterBox struct {
	BoxID           string            `json:"box_id"`
	Online          bool              `json:"online"`
	LastHelloAt     *string           `json:"last_hello_at"`
	OS              *wire.HostOS      `json:"os"`
	Runtimes        map[string]string `json:"runtimes"`
	System          *wire.HostSystem  `json:"system"`
	Network         *wire.HostNetwork `json:"network"`
	FactsReportedAt *string           `json:"facts_reported_at"`
	AgentPresence   map[string]struct {
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
		ReportedAt: "2026-10-04T12:00:00Z",
		OS:         &wire.HostOS{Name: "Debian GNU/Linux", Version: "13", Pretty: "Debian GNU/Linux 13 (trixie)", Kernel: "6.12.111+deb13-cloud-amd64", Arch: "amd64"},
		Runtimes:   map[string]string{"go": "1.25.1", "node": "22.1.0", "claude": "2.1.3", "spool": "8.9.6"},
		System: &wire.HostSystem{Hostname: "box-a", Timezone: "Europe/Helsinki", BootAt: "2026-10-02T13:58:04Z", CPUs: 16,
			CPUModel: "AMD EPYC 7B12", Load: "0.12 0.20 0.30", MemTotalMB: 64305, MemAvailMB: 40756, SwapTotalMB: mb(2048), SwapFreeMB: mb(1024), State: "running"},
		Network: &wire.HostNetwork{IPs: []string{"10.0.0.2", "fd00::2"}, Gateway: "10.0.0.1", DNS: []string{"169.254.169.254"}},
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
	if got.System == nil || !reflect.DeepEqual(*got.System, *host.System) {
		t.Fatalf("system = %+v, want %+v", got.System, host.System)
	}
	if got.Network == nil || fmt.Sprint(*got.Network) != fmt.Sprint(*host.Network) {
		t.Fatalf("network = %+v, want %+v", got.Network, host.Network)
	}
	if got.FactsReportedAt == nil || *got.FactsReportedAt != "2026-10-04T12:00:00Z" {
		t.Fatalf("facts_reported_at = %v", got.FactsReportedAt)
	}
	p, ok := got.AgentPresence["c-001"]
	if !ok || p.State != "online" || p.LastSeen == nil || got.LastHelloAt == nil || *p.LastSeen != *got.LastHelloAt {
		t.Fatalf("agent_presence = %+v (last_hello_at %v)", got.AgentPresence, got.LastHelloAt)
	}
	if o := rs["box-o"]; o.OS != nil || o.Runtimes != nil || o.System != nil || o.Network != nil || o.FactsReportedAt != nil {
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

	// t1 950d5562: a redial without host (an older binary, a one-shot sync)
	// keeps the last sheet; the next hello with one replaces it.
	connectBox(t, e, tid, a, "c-001")
	if got := rosterBoxes(t, e, tid)["box-a"]; got.OS == nil || got.FactsReportedAt == nil {
		t.Fatalf("a hello without host cleared the facts: %+v", got)
	}
	newer := *host
	newer.ReportedAt, newer.OS = "2026-10-05T12:00:00Z", &wire.HostOS{Name: "Debian GNU/Linux", Version: "14"}
	helloHost(t, e, tid, a, &newer, "c-001")
	if got := rosterBoxes(t, e, tid)["box-a"]; got.OS == nil || got.OS.Version != "14" || *got.FactsReportedAt != "2026-10-05T12:00:00Z" {
		t.Fatalf("a newer sheet did not win: %+v", got)
	}
}

func mb(n int64) *int64 { return &n }

// t1 950d5562 ("the sat box has a lot of box info unreported"): the facts
// were hub memory only, and a Cloud Run roll's NEW revision - which answers
// every fresh roster read - said "not reported yet" until the box redialled.
// The sheet is stored (rdb 0140): a second hub process on the same store,
// which no box has said hello to, serves it. A box without swap reads 0.
func TestBoxFactsSurviveHubRestart(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "c-001")
	e.pin(tid, a)
	host := &wire.BoxHost{ReportedAt: "2026-10-05T19:10:22Z",
		OS:       &wire.HostOS{Name: "Debian GNU/Linux", Version: "13"},
		Runtimes: map[string]string{"go": "1.25.14", "claude": "2.1.291"},
		System:   &wire.HostSystem{Hostname: "box-a", CPUs: 16, MemTotalMB: 64305, SwapTotalMB: mb(0), SwapFreeMB: mb(0)},
		Network:  &wire.HostNetwork{IPs: []string{"10.80.0.2"}, Gateway: "10.80.0.1"}}
	helloHost(t, e, tid, a, host, "c-001")
	if s := rosterBoxes(t, e, tid)["box-a"].System; s == nil || s.SwapTotalMB == nil || *s.SwapTotalMB != 0 {
		t.Fatalf("swap 0 dropped: %+v", s)
	}

	next := secondHub(t, e, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
	got := rosterBoxes(t, next, tid)["box-a"]
	if got.FactsReportedAt == nil || *got.FactsReportedAt != "2026-10-05T19:10:22Z" {
		t.Fatalf("a fresh hub lost the facts: %+v", got)
	}
	if got.OS == nil || *got.OS != *host.OS || !reflect.DeepEqual(got.Runtimes, host.Runtimes) ||
		got.System == nil || !reflect.DeepEqual(*got.System, *host.System) ||
		got.Network == nil || !reflect.DeepEqual(*got.Network, *host.Network) {
		t.Fatalf("a fresh hub served %+v", got)
	}
}

// secondHub is another hub process on e's store (a new Cloud Run revision),
// as an env whose requests reach only it.
func secondHub(t *testing.T, e *env, mut ...func(*hub.Options)) *env {
	t.Helper()
	o := hub.Options{
		Store: e.st, Blob: blob.Dir{Root: e.blobs}, Log: zerolog.Nop(),
		TenantHostPattern: "{tenant}" + domain, HelloSkew: 300 * time.Second, HelloTimeout: 2 * time.Second,
		UploadTokenTTL: 5 * time.Minute, QueueTTL: 7 * 24 * time.Hour, QueueMaxPerBox: 1000,
		RetentionAlerts: 7 * 24 * time.Hour, RetentionChannels: 30 * 24 * time.Hour, Version: "test-next",
	}
	for _, m := range mut {
		m(&o)
	}
	srv, err := hub.New(o)
	if err != nil {
		t.Fatal(err)
	}
	n := &env{t: t, st: e.st, srv: srv, ts: httptest.NewServer(srv.Handler()), blobs: e.blobs}
	t.Cleanup(func() { srv.Shutdown(); n.ts.Close() })
	addr := n.ts.Listener.Addr().String()
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	}
	n.client = &http.Client{Transport: tr}
	return n
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
	}, Runtimes: rt,
		ReportedAt: "2999-01-01T00:00:00Z", // in the future: dated by the hello instead
		System: &wire.HostSystem{Hostname: "box\x1b[31m-a", BootAt: "2999-01-01T00:00:00Z", CPUs: -4,
			MemTotalMB: -1, MemAvailMB: 1 << 50, SwapTotalMB: mb(512), SwapFreeMB: mb(-5), Load: strings.Repeat("9 ", 1000)},
		Network: &wire.HostNetwork{
			IPs:     append([]string{"not-an-ip", "10.0.0.1; rm -rf /", "::ffff:10.0.0.9"}, ips(20)...),
			Gateway: "999.1.1.1",
			DNS:     []string{"1.1.1.1", "8.8.8.8", "9.9.9.9", "8.8.4.4", "1.0.0.1", "bogus"},
		}}
	before := time.Now().UTC().Add(-time.Second)
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
	s := got.System
	if s == nil || s.Hostname != "box[31m-a" || s.BootAt != "" || s.CPUs != 0 || s.MemTotalMB != 0 || s.MemAvailMB != 0 ||
		s.SwapTotalMB == nil || *s.SwapTotalMB != 512 || s.SwapFreeMB != nil || s.Load == "" || len(s.Load) > 64 {
		t.Fatalf("system not cut: %+v", s)
	}
	n := got.Network
	if n == nil || len(n.IPs) != 8 || n.IPs[0] != "10.0.0.9" || n.Gateway != "" || len(n.DNS) != 4 {
		t.Fatalf("network not cut: %+v", n)
	}
	if at, err := time.Parse(time.RFC3339, *got.FactsReportedAt); err != nil || at.Before(before) || at.After(time.Now().Add(time.Minute)) {
		t.Fatalf("a future reported_at was kept: %v", *got.FactsReportedAt)
	}
}

// ips is n distinct private addresses.
func ips(n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = fmt.Sprintf("10.1.0.%d", i+1)
	}
	return out
}

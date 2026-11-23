package hubclient

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"reflect"
	"runtime"
	"slices"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The collector of spec 071 7.6.3 (SPL-6239 row T2), the fixture part of the
// 7.8 "box handler" test: fixture /proc files and a stub df give the
// expected sample. The frames, the 60 s guard and the hello feature (row T3)
// are the tests at the end of this file. The parity with the tick's bash collector is
// csi-spl-orc/src/bash/tests/box-sample-parity.tst.sh, through
// TestBoxSampleParityOut below.

// The tick's own fixtures (csi-spl-orc box-stats-cron.tst.sh): a mount with
// a space, a repeated mount, and a network row with dashes.
const (
	boxFixLoadavg = "2.50 1.75 0.47 3/900 12345\n"
	boxFixMeminfo = "MemTotal: 16000000 kB\nMemAvailable: 6000000 kB\nSwapTotal: 1000 kB\nSwapFree: 400 kB\n"
	boxFixDF      = "Filesystem 1024-blocks Used Available Capacity Mounted on\n" +
		"/dev/sda1 100 55 40 58% /\n/dev/sdb1 900 400 500 45% /mnt/my data\n" +
		"/dev/sda1 100 55 40 58% /\nsrv:/x - - - - /net\n"
)

func boxFixtures(t *testing.T) (dir string, s BoxSampler) {
	t.Helper()
	dir = t.TempDir()
	write := func(name, body string) string {
		p := filepath.Join(dir, name)
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	return dir, BoxSampler{Box: "sat", Loadavg: write("loadavg", boxFixLoadavg), Meminfo: write("meminfo", boxFixMeminfo),
		CPUs: func() int { return 8 }, DF: func(context.Context) ([]byte, error) { return []byte(boxFixDF), nil }}
}

func TestBoxSampleCollectFixture(t *testing.T) {
	_, s := boxFixtures(t)
	s.AgentRun = func() map[string]bool { return map[string]bool{"c-001": true, "c-150": true, "c-151": false} }
	got, err := s.Collect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	want := store.BoxStat{Box: "sat", Load1: 2.5, Load5: 1.75, Load15: 0.47, CPUs: 8, MemTotalKB: 16000000,
		MemAvailKB: 6000000, SwapUsedKB: 600, AgentsLive: 2, Disks: []store.BoxDisk{
			{Mount: "/", TotalKB: 100, AvailKB: 40, UsedKB: 55}, {Mount: "/mnt/my data", TotalKB: 900, AvailKB: 500, UsedKB: 400}}}
	if !reflect.DeepEqual(got.Stat, want) || !got.AgentsReported {
		t.Fatalf("sample:\n got %+v reported=%v\nwant %+v reported=true", got.Stat, got.AgentsReported, want)
	}
	if why := store.CheckBoxStat(got.Stat); why != "" {
		t.Fatalf("the hub would refuse it: %s", why)
	}
}

func TestBoxSampleNoRunReport(t *testing.T) {
	_, s := boxFixtures(t)
	for name, run := range map[string]func() map[string]bool{"no func": nil, "stale report": func() map[string]bool { return nil }} {
		s.AgentRun = run
		got, err := s.Collect(context.Background())
		if err != nil || got.AgentsReported || got.Stat.AgentsLive != 0 {
			t.Fatalf("%s: reported=%v agents_live=%d err=%v, want unreported 0", name, got.AgentsReported, got.Stat.AgentsLive, err)
		}
	}
}

func TestBoxSampleUnreadableSendsNothing(t *testing.T) {
	dir, s := boxFixtures(t)
	bad := s
	bad.Loadavg = filepath.Join(dir, "nosuch")
	if _, err := bad.Collect(context.Background()); err == nil {
		t.Fatal("an unreadable loadavg gave a sample")
	}
	noAvail := filepath.Join(dir, "meminfo-short")
	if err := os.WriteFile(noAvail, []byte("MemTotal: 16000000 kB\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	bad = s
	bad.Meminfo = noAvail
	if _, err := bad.Collect(context.Background()); err == nil {
		t.Fatal("a meminfo without MemAvailable gave a sample")
	}
	bad = s
	bad.CPUs = func() int { return 0 }
	if _, err := bad.Collect(context.Background()); err == nil {
		t.Fatal("0 cpus gave a sample")
	}
}

func TestBoxSampleDiskCapAndFailures(t *testing.T) {
	_, s := boxFixtures(t)
	var df strings.Builder
	df.WriteString("head\n")
	for i := 1; i <= 20; i++ {
		fmt.Fprintf(&df, "/dev/x%d 10 1 9 10%% /m%d\n", i, i)
	}
	s.DF = func(context.Context) ([]byte, error) { return []byte(df.String()), nil }
	got, _ := s.Collect(context.Background())
	if n := len(got.Stat.Disks); n != store.BoxDisksMax || got.Stat.Disks[15].Mount != "/m16" {
		t.Fatalf("20 mounts: %d kept, want the first %d", n, store.BoxDisksMax)
	}
	s.DF = func(context.Context) ([]byte, error) { return nil, fmt.Errorf("exit status 1") }
	got, _ = s.Collect(context.Background())
	if raw, _ := json.Marshal(got.Stat.Disks); string(raw) != "[]" {
		t.Fatalf("df fails: disks %s, want []", raw)
	}
}

// A df stuck on a hung mount: Collect still returns, with disks [], once the
// timeout passes. The stub never returns before the test ends (a fixture
// that plays the hung peer, not a wait).
func TestBoxSampleHungDF(t *testing.T) {
	_, s := boxFixtures(t)
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	s.DFTimeout = boxSampleDFTimeout / 30
	s.DF = func(context.Context) ([]byte, error) { <-release; return []byte(boxFixDF), nil }
	got, err := s.Collect(context.Background())
	if raw, _ := json.Marshal(got.Stat.Disks); err != nil || string(raw) != "[]" {
		t.Fatalf("hung df: disks %s err %v, want [] and a sample", raw, err)
	}
}

// Load lines the tick refuses give no sample.
func TestBoxSampleBadLoad(t *testing.T) {
	dir, s := boxFixtures(t)
	for i, line := range []string{"1.0 2.0\n", "1.0 x 3.0\n", "1.2.3 1 1\n"} {
		s.Loadavg = filepath.Join(dir, fmt.Sprintf("loadavg-bad%d", i))
		if err := os.WriteFile(s.Loadavg, []byte(line), 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := s.Collect(context.Background()); err == nil {
			t.Fatalf("loadavg %q gave a sample", line)
		}
	}
}

// The zero value reads the live box: /proc, the CPU count, the real df.
func TestBoxSampleLiveDefaults(t *testing.T) {
	if runtime.GOOS != "linux" {
		t.Skip("/proc is Linux's")
	}
	got, err := BoxSampler{Box: "sat"}.Collect(context.Background())
	if err != nil || got.Stat.CPUs != runtime.NumCPU() || got.Stat.MemTotalKB <= 0 || got.Stat.Disks == nil {
		t.Fatalf("live box: %+v err %v", got.Stat, err)
	}
	if why := store.CheckBoxStat(got.Stat); why != "" {
		t.Fatalf("the hub would refuse the live sample: %s", why)
	}
}

// The default df run: the tick's argv, through exec, on a stub df.
func TestBoxSampleRunDF(t *testing.T) {
	dir := t.TempDir()
	stub := filepath.Join(dir, "df")
	body := "#!/bin/sh\necho \"$@\" >" + filepath.Join(dir, "argv") + "\nprintf '" + strings.ReplaceAll(boxFixDF, "%", "%%") + "'\n"
	if err := os.WriteFile(stub, []byte(body), 0o700); err != nil { // #nosec G306 -- an executable stub
		t.Fatal(err)
	}
	out, err := runBoxDF(context.Background(), append([]string{stub}, boxSampleDFArgv[1:]...))
	if err != nil || len(parseBoxDF(out)) != 2 {
		t.Fatalf("stub df: %q err %v", out, err)
	}
	argv, _ := os.ReadFile(filepath.Join(dir, "argv"))
	if got := strings.TrimSpace(string(argv)); got != "-kP -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs" {
		t.Fatalf("df argv %q, not the tick's", got)
	}
}

// TestBoxSampleParityOut is the Go half of box-sample-parity.tst.sh: with
// BOX_SAMPLE_PARITY_OUT set it collects from the tick's own fixture knobs
// (LANE_LOADAVG, LANE_MEMINFO, LANE_NPROC, LANE_DF_CMD, LANE_BOX) and writes
// the sample's JSON there. Without it there is nothing to compare: skipped.
func TestBoxSampleParityOut(t *testing.T) {
	out := os.Getenv("BOX_SAMPLE_PARITY_OUT")
	if out == "" {
		t.Skip("run by csi-spl-orc/src/bash/tests/box-sample-parity.tst.sh")
	}
	cpus, err := strconv.Atoi(os.Getenv("LANE_NPROC"))
	if err != nil {
		t.Fatalf("LANE_NPROC: %v", err)
	}
	argv := strings.Fields(os.Getenv("LANE_DF_CMD")) // the tick runs $LANE_DF_CMD unquoted: word split, no shell
	if len(argv) == 0 {
		t.Fatal("LANE_DF_CMD is empty")
	}
	s := BoxSampler{Box: os.Getenv("LANE_BOX"), Loadavg: os.Getenv("LANE_LOADAVG"), Meminfo: os.Getenv("LANE_MEMINFO"),
		CPUs: func() int { return cpus }, DF: func(ctx context.Context) ([]byte, error) { return runBoxDF(ctx, argv) }}
	got, err := s.Collect(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	raw, err := json.Marshal(got.Stat)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(out, raw, 0o600); err != nil {
		t.Fatal(err)
	}
}

// The frames of the 7.8 "box handler" test (SPL-6239 row T3): a box_sample
// frame on the role=box socket gets one box_sample_put with the fixture
// sample; the 60 s guard and the one-in-flight limit drop the extra frames;
// a hung df still answers, with disks [], within df's 3 s cap.

// boxSampleHub is a hub that keeps the role=box hello, writes the frames a
// test puts on ask, and hands back every box_sample_put the box writes.
type boxSampleHub struct {
	srv   *httptest.Server
	hello chan wire.Frame
	ask   chan wire.Frame
	puts  chan wire.Frame
}

func newBoxSampleHub(t *testing.T) *boxSampleHub {
	t.Helper()
	h := &boxSampleHub{hello: make(chan wire.Frame, 1), ask: make(chan wire.Frame, 16), puts: make(chan wire.Frame, 16)}
	mux := http.NewServeMux()
	mux.HandleFunc("/v1/ws", h.serveWS)
	mux.HandleFunc("/v1/pins", func(w http.ResponseWriter, r *http.Request) {
		wire.WriteJSON(w, http.StatusOK, wire.PinList{Pins: []wire.PinEntry{}})
	})
	h.srv = httptest.NewServer(mux)
	t.Cleanup(h.srv.Close)
	return h
}

func (h *boxSampleHub) serveWS(w http.ResponseWriter, r *http.Request) {
	conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
	if err != nil {
		return
	}
	defer conn.CloseNow() //nolint:errcheck
	ctx := r.Context()
	var hello wire.Frame
	if wsjson.Write(ctx, conn, wire.Frame{Type: wire.TChallenge, Nonce: "nonce-nonce-nonce"}) != nil || wsjson.Read(ctx, conn, &hello) != nil {
		return
	}
	h.hello <- hello
	if wsjson.Write(ctx, conn, wire.Frame{Type: wire.TWelcome, BoxID: hello.BoxID, UploadToken: "tok",
		UploadTokenExpiresAt: time.Now().Add(time.Hour).UTC().Format(time.RFC3339)}) != nil {
		return
	}
	go func() {
		for {
			var f wire.Frame
			if wsjson.Read(ctx, conn, &f) != nil {
				return
			}
			if f.Type == wire.TBoxSamplePut {
				h.puts <- f
			}
		}
	}()
	for {
		select {
		case f := <-h.ask:
			if wsjson.Write(ctx, conn, f) != nil {
				return
			}
		case <-ctx.Done():
			return
		}
	}
}

// nextPut is the next box_sample_put, or fails the test after 10 s.
func (h *boxSampleHub) nextPut(t *testing.T) wire.Frame {
	t.Helper()
	select {
	case f := <-h.puts:
		return f
	case <-time.After(10 * time.Second):
		t.Fatal("no box_sample_put within 10 s")
		return wire.Frame{}
	}
}

// boxClock is a settable clock for the guard.
type boxClock struct {
	mu sync.Mutex
	t  time.Time
}

func (k *boxClock) now() time.Time { k.mu.Lock(); defer k.mu.Unlock(); return k.t }
func (k *boxClock) add(d time.Duration) {
	k.mu.Lock()
	k.t = k.t.Add(d)
	k.mu.Unlock()
}

// boxSampleSession dials a role=box session on h with the fixture sampler s
// and the clock k.
func boxSampleSession(t *testing.T, h *boxSampleHub, s BoxSampler, k *boxClock) (*Client, *Session) {
	t.Helper()
	c := testClient(t)
	c.Cfg.HubURL, c.Cfg.Tenant = h.srv.URL, "t1"
	c.ReadyTimeout, c.KeepAlive, c.Now = 10*time.Second, -1, k.now
	c.BoxSampler = &s
	sess, err := c.Dial(context.Background(), wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(sess.Close)
	return c, sess
}

// boxSampleIdle waits until no collection is in flight: the put reaches the
// hub just before the handler frees its slot.
func boxSampleIdle(t *testing.T, c *Client) {
	t.Helper()
	for end := time.Now().Add(10 * time.Second); time.Now().Before(end); time.Sleep(time.Millisecond) {
		c.boxSample.mu.Lock()
		busy := c.boxSample.busy
		c.boxSample.mu.Unlock()
		if !busy {
			return
		}
	}
	t.Fatal("box_sample still in flight after 10 s")
}

// boxSampleBarrier returns once the read loop has handled every frame put on
// h.ask before it: it handles frames in order, and this roster lands on disk.
func boxSampleBarrier(t *testing.T, h *boxSampleHub, c *Client, tag string) {
	t.Helper()
	h.ask <- wire.Frame{Type: wire.TRoster, Roster: map[string][]string{tag: {"c-123"}}}
	for end := time.Now().Add(10 * time.Second); c.loadRoster()[tag] == nil; time.Sleep(time.Millisecond) {
		if time.Now().After(end) {
			t.Fatalf("roster frame %s not handled within 10 s", tag)
		}
	}
}

// boxPutStat decodes a put's lane strictly, as the hub will.
func boxPutStat(t *testing.T, f wire.Frame) store.BoxStat {
	t.Helper()
	var st store.BoxStat
	dec := json.NewDecoder(strings.NewReader(string(f.Lane)))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&st); err != nil {
		t.Fatalf("box_sample_put lane %s: %v", f.Lane, err)
	}
	return st
}

func TestBoxSampleFrameAnswers(t *testing.T) {
	h := newBoxSampleHub(t)
	_, s := boxFixtures(t)
	s.Box = "not-this-one" // the session's box wins
	s.AgentRun = func() map[string]bool { return map[string]bool{"c-001": true, "c-150": false} }
	boxSampleSession(t, h, s, &boxClock{t: time.Unix(1700000000, 0)})
	if hl := <-h.hello; !slices.Contains(hl.Features, wire.FeatureBoxSample) {
		t.Fatalf("role=box hello features %v lack %q", hl.Features, wire.FeatureBoxSample)
	}
	h.ask <- wire.Frame{Type: wire.TBoxSample, MsgID: "req-1"}
	f := h.nextPut(t)
	want := store.BoxStat{Box: "box-a", Load1: 2.5, Load5: 1.75, Load15: 0.47, CPUs: 8, MemTotalKB: 16000000,
		MemAvailKB: 6000000, SwapUsedKB: 600, AgentsLive: 1, Disks: []store.BoxDisk{
			{Mount: "/", TotalKB: 100, AvailKB: 40, UsedKB: 55}, {Mount: "/mnt/my data", TotalKB: 900, AvailKB: 500, UsedKB: 400}}}
	if got := boxPutStat(t, f); f.MsgID != "req-1" || !reflect.DeepEqual(got, want) {
		t.Fatalf("box_sample_put msg_id %q lane\n got %+v\nwant msg_id req-1, %+v", f.MsgID, got, want)
	}
}

// RED CONTROL: drop the SPOOL_BOX_SAMPLE_MIN_S check in boxSampleAccept: the
// frame 30 s after the first is answered too, and req-2 comes back.
func TestBoxSampleFrameGuard(t *testing.T) {
	h := newBoxSampleHub(t)
	_, s := boxFixtures(t)
	k := &boxClock{t: time.Unix(1700000000, 0)}
	c, _ := boxSampleSession(t, h, s, k)
	h.ask <- wire.Frame{Type: wire.TBoxSample, MsgID: "req-1"}
	if f := h.nextPut(t); f.MsgID != "req-1" {
		t.Fatalf("first put %q, want req-1", f.MsgID)
	}
	boxSampleIdle(t, c)
	k.add(30 * time.Second)
	h.ask <- wire.Frame{Type: wire.TBoxSample, MsgID: "req-2"} // inside the 60 s: dropped
	h.ask <- wire.Frame{Type: wire.TBoxSample}                 // no request id: dropped
	boxSampleBarrier(t, h, c, "box-y")
	k.add(31 * time.Second)
	h.ask <- wire.Frame{Type: wire.TBoxSample, MsgID: "req-3"} // 61 s after req-1: answered
	if f := h.nextPut(t); f.MsgID != "req-3" {
		t.Fatalf("put after the guard: %q, want req-3 (req-2 came 30 s after req-1, inside the 60 s guard)", f.MsgID)
	}
}

// RED CONTROL: drop the in-flight check in boxSampleAccept: the frame that
// arrives while req-1's df still runs is collected too, and req-2 comes back.
func TestBoxSampleFrameOneInFlight(t *testing.T) {
	h := newBoxSampleHub(t)
	_, s := boxFixtures(t)
	release := make(chan struct{})
	s.DFTimeout = time.Minute
	s.DF = func(context.Context) ([]byte, error) { <-release; return []byte(boxFixDF), nil }
	k := &boxClock{t: time.Unix(1700000000, 0)}
	c, _ := boxSampleSession(t, h, s, k)
	h.ask <- wire.Frame{Type: wire.TBoxSample, MsgID: "req-1"}
	boxSampleBarrier(t, h, c, "box-x") // req-1 taken at the clock's start
	k.add(2 * time.Minute)             // past the 60 s guard: only the in-flight limit stands
	h.ask <- wire.Frame{Type: wire.TBoxSample, MsgID: "req-2"}
	boxSampleBarrier(t, h, c, "box-z") // req-2 refused or taken before req-1 ends
	close(release)
	if f := h.nextPut(t); f.MsgID != "req-1" {
		t.Fatalf("first put %q, want req-1", f.MsgID)
	}
	boxSampleIdle(t, c)
	k.add(2 * time.Minute)
	h.ask <- wire.Frame{Type: wire.TBoxSample, MsgID: "req-3"}
	if f := h.nextPut(t); f.MsgID != "req-3" {
		t.Fatalf("put after req-1: %q, want req-3 (req-2 came while req-1 was in flight)", f.MsgID)
	}
}

// A df stuck on a hung mount: the box still answers, with disks [], within
// df's 3 s cap (plus the frame round trip). The stub never returns before
// the test ends (a fixture that plays the hung peer, not a wait).
func TestBoxSampleFrameHungDF(t *testing.T) {
	h := newBoxSampleHub(t)
	_, s := boxFixtures(t)
	release := make(chan struct{})
	t.Cleanup(func() { close(release) })
	s.DF = func(context.Context) ([]byte, error) { <-release; return []byte(boxFixDF), nil }
	boxSampleSession(t, h, s, &boxClock{t: time.Unix(1700000000, 0)})
	start := time.Now()
	h.ask <- wire.Frame{Type: wire.TBoxSample, MsgID: "req-1"}
	f := h.nextPut(t)
	took := time.Since(start)
	if raw, _ := json.Marshal(boxPutStat(t, f).Disks); f.MsgID != "req-1" || string(raw) != "[]" {
		t.Fatalf("hung df: put %q disks %s, want req-1 and []", f.MsgID, raw)
	}
	if took < boxSampleDFTimeout || took > boxSampleDFTimeout+2*time.Second {
		t.Fatalf("hung df answered after %s, want df's %s cap (+ at most 2 s)", took, boxSampleDFTimeout)
	}
}

func TestParseBoxSampleMin(t *testing.T) {
	for in, want := range map[string]time.Duration{"": DefaultBoxSampleMin, " 90 ": 90 * time.Second, "1": time.Second} {
		if got, err := ParseBoxSampleMin(in); err != nil || got != want {
			t.Errorf("ParseBoxSampleMin(%q) = %s, %v; want %s", in, got, err, want)
		}
	}
	for _, in := range []string{"0", "-5", "60s", "x"} {
		if _, err := ParseBoxSampleMin(in); err == nil {
			t.Errorf("ParseBoxSampleMin(%q) took it", in)
		}
	}
}

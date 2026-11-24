package hub_test

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// TestBoxSampleHelloFeature (spec 071 7.8 "wire feature", row T1): a box
// whose hello carries box_sample gives a session whose features hold it; a
// box whose hello lacks it (an old binary) gives one without it. The
// box_sample_put sample is the box_stats_put object: it decodes into
// store.BoxStat with unknown keys refused.
// RED CONTROL: drop FeatureBoxSample from the hello's features: the session
// lacks it and the test fails.
func TestBoxSampleHelloFeature(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	nb := e.box(tid, "box-new", "CLE-07")
	ob := e.box(tid, "box-old", "CLE-08")
	e.pin(tid, nb)
	e.pin(tid, ob)

	cn := e.kindsHello(tid, nb, "CLE-07", []string{wire.FeatureCommit, wire.FeatureBoxSample})
	defer cn.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	co := e.kindsHello(tid, ob, "CLE-08", []string{wire.FeatureCommit})
	defer co.Close(websocket.StatusNormalClosure, "") //nolint:errcheck

	if got, ok := e.srv.BoxFeatures(tid, "box-new"); !ok || !slices.Contains(got, wire.FeatureBoxSample) {
		t.Errorf("box-new hello with %q: session features %v (live %v), want it held", wire.FeatureBoxSample, got, ok)
	}
	if got, ok := e.srv.BoxFeatures(tid, "box-old"); !ok || slices.Contains(got, wire.FeatureBoxSample) {
		t.Errorf("box-old hello without %q: session features %v (live %v), want it absent", wire.FeatureBoxSample, got, ok)
	}

	f := wire.Frame{Type: wire.TBoxSamplePut, MsgID: "33333333-3333-4333-8333-333333333333",
		Lane: json.RawMessage(`{"box":"box-new","load1":0.5,"load5":0.4,"load15":0.3,"cpus":8,"mem_total_kb":16000000,` +
			`"mem_avail_kb":9000000,"swap_used_kb":0,"agents_live":3,"disks":[{"mount":"/","total_kb":100,"avail_kb":40,"used_kb":55}]}`)}
	raw, err := json.Marshal(f)
	if err != nil {
		t.Fatal(err)
	}
	var back wire.Frame
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&back); err != nil || back.Type != wire.TBoxSamplePut || back.MsgID != f.MsgID {
		t.Fatalf("box_sample_put strict round trip: %+v (%v)", back, err)
	}
	var b store.BoxStat
	dec = json.NewDecoder(bytes.NewReader(back.Lane))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&b); err != nil {
		t.Fatalf("box_sample_put lane is not one box_stats_put object: %v", err)
	}
	if b.Box != "box-new" || b.MemTotalKB != 16000000 || len(b.Disks) != 1 || b.Disks[0].UsedKB != 55 {
		t.Errorf("box_sample_put sample decoded to %+v", b)
	}
	if why := store.CheckBoxStat(b); why != "" {
		t.Errorf("box_sample_put sample refused by CheckBoxStat: %s", why)
	}
}

// samplePeer is hub instance B on e's store (spec 071 7.8 "two-instance
// delivery"): its own server and socket door, its RunWake running, and its
// clock time.Now + skew. It returns once B's box sample listener is up: a
// probe request announced on instance A shows in B's pending map.
func samplePeer(t *testing.T, e *env, tid string, skew *atomic.Int64, mut ...func(*hub.Options)) (*hub.Server, *env) {
	t.Helper()
	o := hub.Options{
		Store: e.st, Blob: blob.Dir{Root: e.blobs}, Log: zerolog.Nop(),
		TenantHostPattern: "{tenant}" + domain, HelloSkew: 300 * time.Second, HelloTimeout: 2 * time.Second,
		UploadTokenTTL: 5 * time.Minute, QueueTTL: 7 * 24 * time.Hour, QueueMaxPerBox: 1000,
		RetentionAlerts: 7 * 24 * time.Hour, RetentionChannels: 30 * 24 * time.Hour, Version: "test-peer",
		Now: func() time.Time { return time.Now().Add(time.Duration(skew.Load())) },
	}
	for _, m := range mut {
		m(&o)
	}
	srv, err := hub.New(o)
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(srv.Handler())
	ctx, cancel := context.WithCancel(context.Background())
	go srv.RunWake(ctx)
	t.Cleanup(func() { cancel(); srv.Shutdown(); ts.Close() })
	addr := ts.Listener.Addr().String()
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = func(ctx context.Context, network, _ string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, addr)
	}
	peer := *e
	peer.srv, peer.ts, peer.client = srv, ts, &http.Client{Transport: tr}
	var probes []string // a probe announced before B listened is lost: ask again
	eventually(t, "instance B's box sample listener is up", func() bool {
		for _, req := range probes {
			if srv.PendingBoxSample(tid, "box-probe", req) {
				return true
			}
		}
		req, _ := e.srv.AskBoxSample(ctx, tid, "box-probe", time.Now().Add(time.Minute))
		probes = append(probes, req)
		return false
	})
	return srv, &peer
}

// sampleFrames reads c in the background and hands on every box_sample
// frame. Reads never time out, so a "no frame" wait leaves the socket open.
func sampleFrames(c *websocket.Conn) <-chan wire.Frame {
	out := make(chan wire.Frame, 8)
	go func() {
		defer close(out)
		for {
			var f wire.Frame
			if err := wsjson.Read(context.Background(), c, &f); err != nil {
				return
			}
			if f.Type == wire.TBoxSample {
				out <- f
			}
		}
	}()
	return out
}

// gotSample is the next box_sample frame of ch within d; false = none.
func gotSample(ch <-chan wire.Frame, d time.Duration) (wire.Frame, bool) {
	select {
	case f, ok := <-ch:
		return f, ok
	case <-time.After(d):
		return wire.Frame{}, false
	}
}

// putSample writes a box_sample_put answering req, its sample naming box.
func putSample(t *testing.T, c *websocket.Conn, req, box string) {
	t.Helper()
	putSampleLoad(t, c, req, box, "0.5")
}

// putSampleLoad is putSample with load1 = load1, a mark a waiter can find.
func putSampleLoad(t *testing.T, c *websocket.Conn, req, box, load1 string) {
	t.Helper()
	f := wire.Frame{Type: wire.TBoxSamplePut, MsgID: req,
		Lane: json.RawMessage(`{"box":"` + box + `","load1":` + load1 + `,"load5":0.4,"load15":0.3,"cpus":8,"mem_total_kb":16000000,` +
			`"mem_avail_kb":9000000,"swap_used_kb":0,"agents_live":3,"disks":[{"mount":"/","total_kb":100,"avail_kb":40,"used_kb":55}]}`)}
	if err := wsjson.Write(context.Background(), c, f); err != nil {
		t.Fatal(err)
	}
}

// boxSampleRig is one tenant with four pinned boxes, instance A (e, its
// RunWake running) and instance B (peer), whose clock skew the test moves.
type boxSampleRig struct {
	e, peer *env
	b       *hub.Server
	tid     string
	boxes   map[string]*box
	skew    *atomic.Int64
}

func newBoxSampleRig(t *testing.T) *boxSampleRig {
	e := newEnv(t)
	tid, _ := e.tenant()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go e.srv.RunWake(ctx)
	r := &boxSampleRig{e: e, tid: tid, boxes: map[string]*box{}, skew: &atomic.Int64{}}
	for id, agent := range map[string]string{"box-new": "CLE-07", "box-old": "CLE-08", "box-late": "CLE-09", "box-gone": "CLE-10"} {
		r.boxes[id] = e.box(tid, id, agent)
		e.pin(tid, r.boxes[id])
	}
	r.b, r.peer = samplePeer(t, e, tid, r.skew)
	return r
}

// ask announces a request for box on instance A, deadline d from now.
func (r *boxSampleRig) ask(t *testing.T, box string, d time.Duration) string {
	t.Helper()
	req, err := r.e.srv.AskBoxSample(context.Background(), r.tid, box, time.Now().Add(d))
	if err != nil {
		t.Fatal(err)
	}
	return req
}

// dial says hello for box on instance B, with or without FeatureBoxSample,
// and reads its box_sample frames from then on.
func (r *boxSampleRig) dial(t *testing.T, box, agent string, featured bool) (*websocket.Conn, <-chan wire.Frame) {
	feats := []string{wire.FeatureCommit}
	if featured {
		feats = append(feats, wire.FeatureBoxSample)
	}
	c := r.peer.kindsHello(r.tid, r.boxes[box], agent, feats)
	t.Cleanup(func() { c.Close(websocket.StatusNormalClosure, "") }) //nolint:errcheck
	return c, sampleFrames(c)
}

// rows is the tenant's stored box stats.
func (r *boxSampleRig) rows(t *testing.T) []store.BoxStat {
	t.Helper()
	rows, err := r.e.st.(store.BoxStats).ListBoxStats(context.Background(), r.tid, "", time.Now().Add(-time.Hour))
	if err != nil {
		t.Fatal(err)
	}
	return rows
}

// TestBoxSampleTwoInstanceDelivery (spec 071 7.8 "two-instance delivery",
// row T5): an announce on instance A puts one box_sample frame on the fake
// box socket held by instance B, and none on a socket whose hello lacked
// box_sample; a box_sample_put is stored only for a pending request of that
// box inside its deadline (an unknown id, a repeat or a late answer stores
// nothing), under the session's box; a box that says hello on B inside the
// deadline gets the frame then, after it none.
// RED CONTROL: plant a frame write that ignores the feature (asks every
// socket): the featureless fake box gets a frame and the test fails.
func TestBoxSampleTwoInstanceDelivery(t *testing.T) {
	r := newBoxSampleRig(t)
	cn, fn := r.dial(t, "box-new", "CLE-07", true)
	_, fo := r.dial(t, "box-old", "CLE-08", false)

	reqOld := r.ask(t, "box-old", time.Minute)
	reqNew := r.ask(t, "box-new", time.Minute)
	if f, ok := gotSample(fn, 5*time.Second); !ok || f.MsgID != reqNew {
		t.Fatalf("box-new (featured, on B) after an announce on A: frame %+v (%v), want msg_id %s", f, ok, reqNew)
	}
	eventually(t, "instance B holds the box-old request", func() bool {
		return r.b.PendingBoxSample(r.tid, "box-old", reqOld)
	})
	if f, ok := gotSample(fo, 500*time.Millisecond); ok {
		t.Errorf("box-old (hello without %s) got a box_sample frame %s", wire.FeatureBoxSample, f.MsgID)
	}
	if f, ok := gotSample(fn, 300*time.Millisecond); ok {
		t.Errorf("box-new got a second box_sample frame %s for one announce", f.MsgID)
	}

	putSample(t, cn, "44444444-4444-4444-8444-444444444444", "box-new") // unknown request id
	putSample(t, cn, reqNew, "box-spoof")                               // stored under the session's box
	putSample(t, cn, reqNew, "box-new")                                 // a repeat: already taken
	r.answerSentinel(t, cn, fn, 2)

	req3 := r.ask(t, "box-new", 30*time.Second)
	if f, ok := gotSample(fn, 5*time.Second); !ok || f.MsgID != req3 {
		t.Fatalf("box-new, third announce: frame %+v (%v), want %s", f, ok, req3)
	}
	r.skew.Store(int64(time.Minute)) // B's clock passes req3's deadline; it only moves on
	putSample(t, cn, req3, "box-new")
	r.answerSentinel(t, cn, fn, 3)

	reqLate := r.ask(t, "box-late", 10*time.Minute)
	eventually(t, "instance B holds the box-late request", func() bool {
		return r.b.PendingBoxSample(r.tid, "box-late", reqLate)
	})
	_, fl := r.dial(t, "box-late", "CLE-09", true)
	if f, ok := gotSample(fl, 5*time.Second); !ok || f.MsgID != reqLate {
		t.Errorf("box-late, hello on B inside the deadline: frame %+v (%v), want %s", f, ok, reqLate)
	}

	reqGone := r.ask(t, "box-gone", 2*time.Minute)
	eventually(t, "instance B holds the box-gone request", func() bool {
		return r.b.PendingBoxSample(r.tid, "box-gone", reqGone)
	})
	r.skew.Store(int64(3 * time.Minute)) // after the deadline, inside the 300 s hello skew
	_, fg := r.dial(t, "box-gone", "CLE-10", true)
	if f, ok := gotSample(fg, 500*time.Millisecond); ok {
		t.Errorf("box-gone, hello on B after the deadline: got frame %s, want none", f.MsgID)
	}
}

// answerSentinel asks box-new once more and answers on cn; the session
// reads frames in order, so once its row (load1 want + 0.77, the mark) is stored
// every earlier box_sample_put on cn was handled. Then the tenant holds
// exactly want rows, every one under box-new written by box-new. (Waiting
// for want rows alone let a wrongly stored earlier row stand in for the
// sentinel's: the count passed before the sentinel landed.)
func (r *boxSampleRig) answerSentinel(t *testing.T, cn *websocket.Conn, fn <-chan wire.Frame, want int) {
	t.Helper()
	req := r.ask(t, "box-new", 10*time.Minute) // past any skew the test sets
	if f, ok := gotSample(fn, 5*time.Second); !ok || f.MsgID != req {
		t.Fatalf("box-new, sentinel announce: frame %+v (%v), want %s", f, ok, req)
	}
	mark := float64(want) + 0.77 // one mark per sentinel: a test may call it twice
	putSampleLoad(t, cn, req, "box-new", strconv.FormatFloat(mark, 'f', 2, 64))
	eventually(t, "the sentinel sample stored", func() bool {
		return slices.ContainsFunc(r.rows(t), func(b store.BoxStat) bool { return b.Load1 == mark })
	})
	rows := r.rows(t)
	if len(rows) != want {
		t.Fatalf("stored %d box stats, want %d: an unsolicited, repeated or late box_sample_put was stored", len(rows), want)
	}
	for _, b := range rows {
		if b.Box != "box-new" || b.WriterBox != "box-new" {
			t.Errorf("stored sample box %q writer %q, want both box-new (the session's box)", b.Box, b.WriterBox)
		}
	}
}

// ---- row T6: the Refresh route (spec 071 7.8 "refresh contract", "silent
// box is stale", "a never-sampled box (W3)", "limits") ----

// refreshWait is the rigs' wait cap: short, so a silent box's answer comes
// soon; a fresh answer must still come well inside it.
const refreshWait = 2 * time.Second

// memberDoor is rbacEnv's door on a peer instance: a member is named by
// memberHeader and seated through the shared store.
func memberDoor(o *hub.Options) {
	o.ViewDoor = hub.ViewDoorOff
	o.SessionID = func(r *http.Request, _ string) (string, error) {
		if v := r.Header.Get(memberHeader); v != "" {
			return v, nil
		}
		return "", errors.New("no session")
	}
}

// refreshRig is instance A (rbacEnv, the route, RunWake), instance B (a peer
// on the same store, holding the fake boxes' sockets, the route too), one
// tenant with an admin, and the boxes it pins.
type refreshRig struct {
	*boxSampleRig
	admin string
}

func newRefreshRig(t *testing.T, ids ...string) *refreshRig {
	limits := func(o *hub.Options) { o.BoxRefresh = hub.BoxRefreshLimits{Wait: refreshWait} }
	e := rbacEnv(t, limits)
	tid, _ := e.tenant()
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	go e.srv.RunWake(ctx)
	r := &boxSampleRig{e: e, tid: tid, boxes: map[string]*box{}, skew: &atomic.Int64{}}
	for _, id := range ids {
		r.boxes[id] = e.box(tid, id) // no agents: no roster row (W1/W3)
		e.pin(tid, r.boxes[id])
	}
	r.b, r.peer = samplePeer(t, e, tid, r.skew, memberDoor, limits)
	return &refreshRig{boxSampleRig: r, admin: seat(t, e, tid, rbac.Admin)}
}

// bareDial says hello for box on instance B announcing no agents (so no
// roster row), with or without FeatureBoxSample, and reads its box_sample
// frames from then on.
func (r *refreshRig) bareDial(t *testing.T, id string, featured bool) (*websocket.Conn, <-chan wire.Frame) {
	t.Helper()
	feats := []string{wire.FeatureCommit}
	if featured {
		feats = append(feats, wire.FeatureBoxSample)
	}
	c, nonce := r.peer.raw(r.tid)
	h := helloFrame(r.boxes[id], nonce, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	h.Agents, h.MsgVersions, h.Features = nil, msg.Supported, feats
	if err := wsjson.Write(context.Background(), c, h); err != nil {
		t.Fatal(err)
	}
	rctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		var f wire.Frame
		if err := wsjson.Read(rctx, c, &f); err != nil {
			t.Fatalf("%s: no welcome after a hello without agents: %v", id, err)
		}
		if f.Type == wire.TWelcome {
			break
		}
	}
	t.Cleanup(func() { c.Close(websocket.StatusNormalClosure, "") }) //nolint:errcheck
	return c, sampleFrames(c)
}

// seed stores one tick sample of box at at, as an old 5-minute row.
func (r *refreshRig) seed(t *testing.T, id string, at time.Time) {
	t.Helper()
	b := store.BoxStat{Box: id, WriterBox: id, At: at, Load1: 0.1, CPUs: 4, MemTotalKB: 1000, MemAvailKB: 500, Disks: []store.BoxDisk{}}
	if err := r.e.st.(store.BoxStats).AppendBoxStat(context.Background(), r.tid, b); err != nil {
		t.Fatal(err)
	}
}

type refreshAnswer struct {
	code    int
	retry   string
	elapsed time.Duration
	AskedAt time.Time `json:"asked_at"`
	WaitMS  int64     `json:"wait_ms"`
	Boxes   []struct {
		Box   string         `json:"box"`
		State string         `json:"state"`
		Row   *store.BoxStat `json:"row"`
	} `json:"boxes"`
	Permission string `json:"permission"`
}

// state is box's state in the answer, "" = not in it; and its row.
func (a refreshAnswer) state(id string) (string, *store.BoxStat) {
	for _, b := range a.Boxes {
		if b.Box == id {
			return b.State, b.Row
		}
	}
	return "", nil
}

// refresh POSTs body to the route on e as hum; its answer arrives on the channel.
func refresh(e *env, tid, hum, body string) <-chan refreshAnswer {
	out := make(chan refreshAnswer, 1)
	go func() {
		req, _ := http.NewRequest(http.MethodPost, e.url(tid)+"/v1/tenant/box-stats/refresh", strings.NewReader(body))
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set(memberHeader, hum)
		start := time.Now()
		var a refreshAnswer
		resp, err := e.client.Do(req)
		if err != nil {
			a.code = -1
			out <- a
			return
		}
		defer resp.Body.Close()
		json.NewDecoder(resp.Body).Decode(&a) //nolint:errcheck
		a.code, a.retry, a.elapsed = resp.StatusCode, resp.Header.Get("Retry-After"), time.Since(start)
		out <- a
	}()
	return out
}

// answered waits for an answer, at most the wait cap + 5 s.
func answered(t *testing.T, ch <-chan refreshAnswer) refreshAnswer {
	t.Helper()
	select {
	case a := <-ch:
		if a.code == -1 {
			t.Fatal("refresh: request failed")
		}
		return a
	case <-time.After(refreshWait + 5*time.Second):
		t.Fatal("refresh: no answer within the wait cap + 5 s")
	}
	return refreshAnswer{}
}

// TestBoxRefreshContract (spec 071 7.8 "refresh contract", row T6): a fake
// box with the feature on instance B; POST on instance A answers fresh for
// it within the wait cap + 1 s, with the row it sent (at >= asked_at), and
// no fixed sleep: the box answers the frame it is sent, the test waits on
// the answer.
// RED CONTROL: the fake box sends its hello without box_sample: the answer
// is stale and the test fails.
func TestBoxRefreshContract(t *testing.T) {
	r := newRefreshRig(t, "box-new")
	r.seed(t, "box-new", time.Now().Add(-10*time.Minute))
	cn, fn := r.bareDial(t, "box-new", true)

	ch := refresh(r.e, r.tid, r.admin, `{"box":"box-new"}`)
	if f, ok := gotSample(fn, 5*time.Second); ok {
		putSample(t, cn, f.MsgID, "box-new")
	}
	a := answered(t, ch)
	st, row := a.state("box-new")
	if a.code != http.StatusOK || st != "fresh" || row == nil || row.At.Before(a.AskedAt) || row.CPUs != 8 {
		t.Fatalf("POST refresh on A, box answering on B: %d state %q row %+v asked_at %s, want 200 fresh with the box's 8-CPU row", a.code, st, row, a.AskedAt)
	}
	if a.elapsed > refreshWait+time.Second {
		t.Errorf("fresh answer took %s, want within the wait cap %s + 1 s", a.elapsed, refreshWait)
	}
}

// TestBoxRefreshSilentBoxIsStale (spec 071 7.8 "silent box is stale"): a
// fake box with the feature that never answers: the answer comes at the
// cap, stale, with its last row and that row's own at.
// RED CONTROL: plant a hub that labels any box with a row fresh: the test
// fails.
func TestBoxRefreshSilentBoxIsStale(t *testing.T) {
	r := newRefreshRig(t, "box-new")
	old := time.Now().Add(-10 * time.Minute).UTC().Truncate(time.Second)
	r.seed(t, "box-new", old)
	_, fn := r.bareDial(t, "box-new", true)

	ch := refresh(r.e, r.tid, r.admin, `{}`)
	if _, ok := gotSample(fn, 5*time.Second); !ok {
		t.Fatal("the silent box was not asked")
	}
	a := answered(t, ch)
	st, row := a.state("box-new")
	if a.code != http.StatusOK || st != "stale" || row == nil || !row.At.Equal(old) {
		t.Fatalf("silent box: %d state %q row %+v, want 200 stale with its last row at %s", a.code, st, row, old)
	}
	if a.elapsed < refreshWait-250*time.Millisecond || a.elapsed > refreshWait+time.Second {
		t.Errorf("silent box answered after %s, want at the cap %s", a.elapsed, refreshWait)
	}
}

// TestBoxRefreshNeverSampledBox (spec 071 7.8 "a never-sampled box (W3)"):
// a pinned box with no roster row (it announced no agents), a live featured
// socket and no row in box_stats at all is asked; its answer is stored and
// the POST answers fresh with that row. The same kind of box with no socket
// answers never. A revoked pin and box-wui are not asked.
// RED CONTROLS: the asked set as "boxes with a sample in 24 h", and the
// asked set as Store.Roster: the bare box is not asked, the test fails.
func TestBoxRefreshNeverSampledBox(t *testing.T) {
	r := newRefreshRig(t, "box-bare", "box-dark", "box-gone")
	now := time.Now()
	if err := r.e.st.RevokePin(context.Background(), r.tid, "box-gone", now.Add(time.Second), now); err != nil {
		t.Fatal(err)
	}
	wui := r.e.box(r.tid, hub.WUIBox)
	r.e.pin(r.tid, wui)
	cn, fn := r.bareDial(t, "box-bare", true)

	ch := refresh(r.e, r.tid, r.admin, `{}`)
	if f, ok := gotSample(fn, 5*time.Second); !ok {
		t.Fatal("box-bare (pinned, no roster row, no sample) was not asked")
	} else {
		putSample(t, cn, f.MsgID, "box-bare")
	}
	a := answered(t, ch)
	if st, row := a.state("box-bare"); a.code != http.StatusOK || st != "fresh" || row == nil || row.Box != "box-bare" {
		t.Errorf("box-bare: %d state %q row %+v, want fresh with the row it sent", a.code, st, row)
	}
	if st, row := a.state("box-dark"); st != "never" || row != nil {
		t.Errorf("box-dark (no socket, no sample): state %q row %+v, want never and no row", st, row)
	}
	for _, id := range []string{"box-gone", hub.WUIBox} {
		if st, _ := a.state(id); st != "" || r.e.srv.PendingBoxSampleFor(r.tid, id) {
			t.Errorf("%s (a revoked pin / the browser box) was asked: state %q", id, st)
		}
	}
	if len(r.rows(t)) != 1 {
		t.Errorf("stored %d box stats, want box-bare's one", len(r.rows(t)))
	}
}

// TestBoxRefreshLimits (spec 071 7.8 "limits"): a second click inside
// MinAge writes no second frame (frames counted on the fake box) and reads
// recent; the 13th click in an hour is 429 with Retry-After; an
// unsolicited box_sample_put stores nothing; product_owner gets 403.
// RED CONTROL: drop each check in turn (the MinAge skip, the hourly count,
// the pending-request check of box_sample_put, tenant.settings): its case
// fails.
func TestBoxRefreshLimits(t *testing.T) {
	r := newRefreshRig(t, "box-new")
	cn, fn := r.bareDial(t, "box-new", true)

	ch := refresh(r.e, r.tid, r.admin, `{}`)
	f, ok := gotSample(fn, 5*time.Second)
	if !ok {
		t.Fatal("click 1: box-new was not asked")
	}
	putSample(t, cn, f.MsgID, "box-new")
	if st, _ := answered(t, ch).state("box-new"); st != "fresh" {
		t.Fatalf("click 1: state %q, want fresh", st)
	}
	if st, _ := answered(t, refresh(r.e, r.tid, r.admin, `{}`)).state("box-new"); st != "recent" {
		t.Errorf("click 2 inside %s: state %q, want recent (not asked)", 60*time.Second, st)
	}
	// An unsolicited answer, then a sentinel request answered on the same
	// socket: frames are read in order, so once the sentinel is the next
	// frame click 2 wrote none, and once its row is stored the unsolicited
	// one was handled.
	putSample(t, cn, "55555555-5555-4555-8555-555555555555", "box-new")
	r.answerSentinel(t, cn, fn, 2)

	po := seat(t, r.e, r.tid, rbac.ProductOwner)
	if a := answered(t, refresh(r.e, r.tid, po, `{}`)); a.code != http.StatusForbidden || a.Permission != rbac.TenantSettings {
		t.Errorf("product_owner: %d permission %q, want 403 %s", a.code, a.Permission, rbac.TenantSettings)
	}
	for i := 3; i <= 12; i++ {
		if a := answered(t, refresh(r.e, r.tid, r.admin, `{}`)); a.code != http.StatusOK {
			t.Fatalf("click %d: %d, want 200", i, a.code)
		}
	}
	if a := answered(t, refresh(r.e, r.tid, r.admin, `{}`)); a.code != http.StatusTooManyRequests || a.retry == "" {
		t.Errorf("click 13 in the hour: %d Retry-After %q, want 429 with Retry-After", a.code, a.retry)
	}
	if a := answered(t, refresh(r.e, r.tid, r.admin, `{"box":"box-none"}`)); a.code != http.StatusNotFound {
		t.Errorf("a box the workspace does not pin: %d, want 404", a.code)
	}
}

// TestBoxRefreshOneRequestPerBox (spec 071 7.6.2, review N1/N2 on T5): the
// pending map is keyed by request id, so two requests for one box can both
// be outstanding (two instances that ask inside one NOTIFY's latency): each
// gets its own frame and each answer is stored once. Through the route a
// box is asked once while a request for it is pending on any instance: a
// click on B while A's run waits on a silent box writes no second frame.
// RED CONTROL: drop the pending check in runBoxRefresh: the silent box gets
// a second frame and the test fails.
func TestBoxRefreshOneRequestPerBox(t *testing.T) {
	r := newRefreshRig(t, "box-new", "box-mute")
	cn, fn := r.bareDial(t, "box-new", true)
	req1, req2 := r.ask(t, "box-new", time.Minute), r.ask(t, "box-new", time.Minute)
	got := map[string]bool{}
	for range 2 {
		if f, ok := gotSample(fn, 5*time.Second); ok {
			got[f.MsgID] = true
		}
	}
	if !got[req1] || !got[req2] {
		t.Fatalf("two outstanding requests for box-new: frames %v, want %s and %s", got, req1, req2)
	}
	putSample(t, cn, req1, "box-new")
	putSample(t, cn, req2, "box-new")
	putSample(t, cn, req1, "box-new") // a repeat: already taken
	r.answerSentinel(t, cn, fn, 3)

	_, fm := r.bareDial(t, "box-mute", true)
	chA := refresh(r.e, r.tid, r.admin, `{"box":"box-mute"}`)
	if _, ok := gotSample(fm, 5*time.Second); !ok {
		t.Fatal("box-mute was not asked by the click on A")
	}
	eventually(t, "instance B holds A's box-mute request", func() bool { return r.b.PendingBoxSampleFor(r.tid, "box-mute") })
	chB := refresh(r.peer, r.tid, r.admin, `{"box":"box-mute"}`)
	for _, a := range []refreshAnswer{answered(t, chA), answered(t, chB)} {
		if st, _ := a.state("box-mute"); a.code != http.StatusOK || st != "never" {
			t.Errorf("box-mute (silent, never sampled): %d state %q, want never", a.code, st)
		}
	}
	if f, ok := gotSample(fm, 300*time.Millisecond); ok {
		t.Errorf("box-mute got a second frame %s while A's request was pending", f.MsgID)
	}
}

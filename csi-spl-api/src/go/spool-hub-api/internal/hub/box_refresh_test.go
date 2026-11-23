package hub_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net"
	"net/http"
	"net/http/httptest"
	"slices"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
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
func samplePeer(t *testing.T, e *env, tid string, skew *atomic.Int64) (*hub.Server, *env) {
	t.Helper()
	srv, err := hub.New(hub.Options{
		Store: e.st, Blob: blob.Dir{Root: e.blobs}, Log: zerolog.Nop(),
		TenantHostPattern: "{tenant}" + domain, HelloSkew: 300 * time.Second, HelloTimeout: 2 * time.Second,
		UploadTokenTTL: 5 * time.Minute, QueueTTL: 7 * 24 * time.Hour, QueueMaxPerBox: 1000,
		RetentionAlerts: 7 * 24 * time.Hour, RetentionChannels: 30 * 24 * time.Hour, Version: "test-peer",
		Now: func() time.Time { return time.Now().Add(time.Duration(skew.Load())) },
	})
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
	f := wire.Frame{Type: wire.TBoxSamplePut, MsgID: req,
		Lane: json.RawMessage(`{"box":"` + box + `","load1":0.5,"load5":0.4,"load15":0.3,"cpus":8,"mem_total_kb":16000000,` +
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
// reads frames in order, so once its row is stored every earlier
// box_sample_put on cn was handled. Then the tenant holds exactly want
// rows, every one under box-new written by box-new.
func (r *boxSampleRig) answerSentinel(t *testing.T, cn *websocket.Conn, fn <-chan wire.Frame, want int) {
	t.Helper()
	req := r.ask(t, "box-new", 10*time.Minute) // past any skew the test sets
	if f, ok := gotSample(fn, 5*time.Second); !ok || f.MsgID != req {
		t.Fatalf("box-new, sentinel announce: frame %+v (%v), want %s", f, ok, req)
	}
	putSample(t, cn, req, "box-new")
	eventually(t, "the sentinel sample stored", func() bool { return len(r.rows(t)) >= want })
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

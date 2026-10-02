package hub_test

import (
	"context"
	"fmt"
	"sync/atomic"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// spec 059 §11 S2 (rdb 0100): a box that commits gets back what it was sent
// and never committed. The spike's test 3 (spec 059 §10): the box reads 5 of
// 10 recv frames, commits the first 4 and dies; before S2 the hub held
// nothing for it and 6 of 10 were lost.

// commitBox is a hand-driven role=box socket; commit=true announces the
// commit feature as an upgraded sidecar does.
func (e *env) commitBox(tenant string, b *box, agent string, commit bool) *rawBox {
	e.t.Helper()
	c, nonce := e.raw(tenant)
	h := helloFrame(b, nonce, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	h.Agents = []string{agent}
	if commit {
		h.Features = []string{wire.FeatureCommit}
	}
	wsjson.Write(context.Background(), c, h) //nolint:errcheck
	r := &rawBox{t: e.t, c: c}
	r.next(wire.TWelcome)
	r.next(wire.TQueueEnd)
	return r
}

func recvMsgID(t *testing.T, f wire.Frame) (string, string) {
	t.Helper()
	env, err := wire.ParseEnvelope(f.Env)
	if err != nil {
		t.Fatal(err)
	}
	m, err := env.Inner()
	if err != nil {
		t.Fatal(err)
	}
	return m.MsgID, m.Body
}

// crashAfterFour sends 10 to the box, reads 5 recv frames, commits the first
// 4, then drops the socket. It returns the bodies the "crashed" box handled.
func crashAfterFour(t *testing.T, e *env, tid string, s, c *box, commit bool) map[string]bool {
	t.Helper()
	raw := e.commitBox(tid, c, "CLE-13", commit)
	for i := 0; i < 10; i++ {
		send(t, s, "GRK-03", "CLE-13", "note", fmt.Sprintf("m%d", i), "box-c")
	}
	handled := map[string]bool{}
	for i := 0; i < 5; i++ {
		id, body := recvMsgID(t, raw.next(wire.TRecv))
		if i < 4 {
			handled[body] = true
			wsjson.Write(context.Background(), raw.c, wire.Frame{Type: wire.TCommit, MsgID: id}) //nolint:errcheck
		}
	}
	time.Sleep(100 * time.Millisecond) // the four commits land before the crash
	raw.c.CloseNow()                   //nolint:errcheck
	time.Sleep(200 * time.Millisecond)
	return handled
}

func TestCommitRedeliversWhatACrashedBoxNeverCommitted(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	s := e.box(tid, "box-s", "GRK-03")
	c := e.box(tid, "box-c", "CLE-13")
	e.pin(tid, s)
	e.pin(tid, c)
	handled := crashAfterFour(t, e, tid, s, c, true)
	if _, err := c.c.Sync(context.Background()); err != nil {
		t.Fatal(err)
	}
	got := map[string]int{}
	for _, b := range bodies(t, c, "CLE-13") {
		got[b]++
	}
	for i := 0; i < 10; i++ {
		b := fmt.Sprintf("m%d", i)
		want := 1
		if handled[b] {
			want = 0 // committed by the crashed box: not sent again
		}
		if got[b] != want {
			t.Fatalf("%s reached the fresh session %d times, want %d (all: %v)", b, got[b], want, got)
		}
	}
	// The fresh session committed what it wrote: a second sync replays nothing.
	time.Sleep(200 * time.Millisecond)
	if r, err := c.c.Sync(context.Background()); err != nil || r.Delivered != 0 {
		t.Fatalf("second sync delivered %d (%v), want 0", r.Delivered, err)
	}
}

// CONTROL: the same crash from a box WITHOUT the commit feature keeps the old
// meaning (sent = acked), so nothing comes back: the loss S2 removes.
func TestCommitOffKeepsTheOldMeaning(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	s := e.box(tid, "box-s", "GRK-03")
	c := e.box(tid, "box-c", "CLE-13")
	e.pin(tid, s)
	e.pin(tid, c)
	crashAfterFour(t, e, tid, s, c, false)
	q, err := e.st.QueuedFor(context.Background(), tid, "box-c", time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if len(q) != 0 {
		t.Fatalf("a legacy box left %d queued rows, want 0 (all 10 were written to its socket)", len(q))
	}
}

// On a live socket an uncommitted row goes out again once the acquisition
// lock (60 s) runs out, at the relay tick; a committed one never does.
func TestCommitAckTimeoutRepushesOnALiveSocket(t *testing.T) {
	var skew atomic.Int64
	e := newEnv(t, func(o *hub.Options) {
		o.Now = func() time.Time { return time.Now().Add(time.Duration(skew.Load())) }
	})
	tid, _ := e.tenant()
	s := e.box(tid, "box-s", "GRK-03")
	c := e.box(tid, "box-c", "CLE-13")
	e.pin(tid, s)
	e.pin(tid, c)
	raw := e.commitBox(tid, c, "CLE-13", true)
	send(t, s, "GRK-03", "CLE-13", "note", "kept", "box-c")
	send(t, s, "GRK-03", "CLE-13", "note", "dropped", "box-c")
	for i := 0; i < 2; i++ {
		id, body := recvMsgID(t, raw.next(wire.TRecv))
		if body == "kept" {
			wsjson.Write(context.Background(), raw.c, wire.Frame{Type: wire.TCommit, MsgID: id}) //nolint:errcheck
		}
	}
	time.Sleep(100 * time.Millisecond)
	// nextBody reads the next recv frame and commits it; a sentinel sent
	// after a relay tick proves the tick pushed nothing ahead of it (a read
	// with a deadline would close the socket).
	nextBody := func() string {
		id, body := recvMsgID(t, raw.next(wire.TRecv))
		wsjson.Write(context.Background(), raw.c, wire.Frame{Type: wire.TCommit, MsgID: id}) //nolint:errcheck
		return body
	}
	e.srv.Relay(context.Background()) // inside the lock: nothing
	send(t, s, "GRK-03", "CLE-13", "note", "sentinel 1", "box-c")
	if b := nextBody(); b != "sentinel 1" {
		t.Fatalf("got %q inside the lock, want sentinel 1", b)
	}
	time.Sleep(100 * time.Millisecond) // sentinel 1's commit lands first
	skew.Store(int64(61 * time.Second))
	e.srv.Relay(context.Background())
	if b := nextBody(); b != "dropped" {
		t.Fatalf("re-pushed %q, want the uncommitted one", b)
	}
	time.Sleep(100 * time.Millisecond)
	e.srv.Relay(context.Background()) // committed now: nothing more
	send(t, s, "GRK-03", "CLE-13", "note", "sentinel 2", "box-c")
	if b := nextBody(); b != "sentinel 2" {
		t.Fatalf("got %q after the commit, want sentinel 2", b)
	}
}

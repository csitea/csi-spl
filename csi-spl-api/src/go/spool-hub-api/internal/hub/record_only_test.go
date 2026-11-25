package hub_test

import (
	"context"
	"errors"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 058 section 7 (SPL-6513, latency action 3): a same-box message is
// delivered locally and then reaches the hub as a record-only copy, stored
// once by msg_id and delivered to no box.

// record sends the record-only copy of a local message out.
func record(t *testing.T, b *box, from, to, kind, body string, out action.SendResult) action.SendResult {
	t.Helper()
	r, err := action.SendCtx(context.Background(), b.cfg, action.SendArgs{
		From: from, To: to, Kind: kind, Body: body, TaskID: out.TaskID, RecordOf: out.MsgID, Hub: b.c,
	})
	if err != nil {
		t.Fatalf("record %s: %v", out.MsgID, err)
	}
	return r
}

func hasMsg(t *testing.T, st store.Store, tid, id string) bool {
	t.Helper()
	ok, err := st.HasMessage(context.Background(), tid, id)
	if err != nil {
		t.Fatal(err)
	}
	return ok
}

// noDelivery fails when the hub holds a delivery row of id for box.
func noDelivery(t *testing.T, st store.Store, tid, id, box string) {
	t.Helper()
	if s, err := st.DeliveryState(context.Background(), tid, id, box); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("%s has a delivery to %s: %q %v", id, box, s, err)
	}
}

func TestRecordOnlySameBoxOneInboxOneRecord(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "c-001", "c-002")
	e.pin(tid, a)
	ctx := context.Background()
	// box-a holds its session, so a delivery the hub made would land in an inbox.
	sa, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sa)

	const n = 20
	var lat []time.Duration
	ids := map[string]bool{}
	for i := 0; i < n; i++ {
		t0 := time.Now()
		out := send(t, a, "c-001", "c-002", "note", "same box", "")
		if out.Delivery != wire.DeliveryLocal {
			t.Fatalf("local send: delivery %q", out.Delivery)
		}
		if r := record(t, a, "c-001", "c-002", "note", "same box", out); r.Delivery != wire.DeliveryRecorded || r.MsgID != out.MsgID {
			t.Fatalf("record: %+v, want delivery recorded and msg_id %s", r, out.MsgID)
		}
		eventually(t, "the hub record", func() bool { return hasMsg(t, e.st, tid, out.MsgID) })
		lat = append(lat, time.Since(t0))
		ids[out.MsgID] = true
		noDelivery(t, e.st, tid, out.MsgID, "box-a")
	}
	sort.Slice(lat, func(i, j int) bool { return lat[i] < lat[j] })
	p95 := lat[(len(lat)*95+99)/100-1]
	t.Logf("record-only: n=%d p50=%s p95=%s max=%s (local send to hub record)", n, lat[n/2], p95, lat[n-1])
	if p95 > 10*time.Second {
		t.Fatalf("p95 %s is over the 10 s target", p95)
	}
	// Exactly one inbox file per message: nothing came back through the hub.
	watch(500*time.Millisecond, func() bool { return len(inbox(t, a, "c-002")) > n })
	got := inbox(t, a, "c-002")
	if len(got) != n {
		t.Fatalf("c-002 inbox holds %d messages, want %d", len(got), n)
	}
	for _, m := range got {
		if !ids[m.MsgID] {
			t.Fatalf("unexpected inbox message %s", m.MsgID)
		}
	}
}

func TestRecordOnlyReplayRecordsNothing(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "c-001", "c-002")
	b := e.box(tid, "box-b", "c-003")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	since := time.Now().Add(-time.Hour)

	out := send(t, a, "c-001", "c-002", "note", "first", "")
	record(t, a, "c-001", "c-002", "note", "first", out)
	n1, err := e.st.CountMessagesSince(ctx, tid, since)
	if err != nil {
		t.Fatal(err)
	}
	// A replay of the same msg_id, signed again (a new ts, another body),
	// answers recorded and stores nothing.
	time.Sleep(1100 * time.Millisecond) // a new RFC3339 second: a different envelope
	if r := record(t, a, "c-001", "c-002", "note", "changed", out); r.Delivery != wire.DeliveryRecorded {
		t.Fatalf("replay: delivery %q", r.Delivery)
	}
	if n2, _ := e.st.CountMessagesSince(ctx, tid, since); n2 != n1 {
		t.Fatalf("replay stored a row: %d -> %d", n1, n2)
	}
	noDelivery(t, e.st, tid, out.MsgID, "box-a")
	if len(inbox(t, a, "c-002")) != 1 {
		t.Fatal("replay delivered a second inbox file")
	}

	// A cross-box message already on the hub: its record copy adds nothing.
	eventually(t, "c-003@box-b on box-a's roster", func() bool {
		tb, err := a.c.ResolveToBox("c-003", "")
		return err == nil && tb == "box-b"
	})
	x := send(t, a, "c-001", "c-003", "note", "cross", "box-b")
	n3, _ := e.st.CountMessagesSince(ctx, tid, since)
	if r := record(t, a, "c-001", "c-003", "note", "cross", x); r.Delivery != wire.DeliveryRecorded {
		t.Fatalf("record of a cross-box message: delivery %q", r.Delivery)
	}
	if n4, _ := e.st.CountMessagesSince(ctx, tid, since); n4 != n3 {
		t.Fatalf("record of a stored cross-box message stored a row: %d -> %d", n3, n4)
	}
	noDelivery(t, e.st, tid, x.MsgID, "box-a")
}

func TestRecordOnlyHubDownQueuesThenFlushes(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	a := e.box(tid, "box-a", "c-001", "c-002")
	e.pin(tid, a)
	ctx := context.Background()
	up := a.c.HTTP
	down := &http.Client{Transport: &http.Transport{DialContext: func(context.Context, string, string) (net.Conn, error) {
		return nil, errors.New("hub down")
	}}}

	out := send(t, a, "c-001", "c-002", "note", "while down", "")
	a.c.HTTP = down
	t0 := time.Now()
	r := record(t, a, "c-001", "c-002", "note", "while down", out)
	t.Logf("record with the hub down: delivery %s in %s", r.Delivery, time.Since(t0))
	if r.Delivery != wire.DeliveryPending {
		t.Fatalf("hub down: delivery %q, want pending", r.Delivery)
	}
	q, err := filepath.Glob(filepath.Join(a.cfg.HubDir(), "pending-record", "*--"+out.MsgID+".json"))
	if err != nil || len(q) != 1 {
		t.Fatalf("record queue: %v %v", q, err)
	}
	if p, _ := a.c.Pending(); len(p) != 0 {
		t.Fatalf("a record went to pending/, where an older sidecar would deliver it: %v", p)
	}
	if hasMsg(t, e.st, tid, out.MsgID) || len(inbox(t, a, "c-002")) != 1 {
		t.Fatal("the local delivery is not exactly one inbox file, or the hub holds the record while down")
	}

	a.c.HTTP = up
	sa, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sa)
	if n, err := sa.Flush(ctx); err != nil || n != 1 {
		t.Fatalf("flush: %d %v, want 1 record", n, err)
	}
	if !hasMsg(t, e.st, tid, out.MsgID) {
		t.Fatal("the flushed record is not on the hub")
	}
	noDelivery(t, e.st, tid, out.MsgID, "box-a")
	if _, err := os.Stat(q[0]); !os.IsNotExist(err) {
		t.Fatalf("the sent record is still queued: %v", err)
	}
	watch(300*time.Millisecond, func() bool { return len(inbox(t, a, "c-002")) > 1 })
	if len(inbox(t, a, "c-002")) != 1 {
		t.Fatal("the flushed record was delivered again")
	}
}

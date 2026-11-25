package hubclient

// Spec 058 section 7 (SPL-6513): the box half of a record-only copy. The hub
// half, against the real hub on the memory store and Postgres, is
// internal/hub/record_only_test.go.

import (
	"context"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

func recMsg(t *testing.T, c *Client, body string) *msg.Message {
	t.Helper()
	m, err := spool.New(c.Cfg).Compose("GRK-03", "CLE-07", "", "note", body, nil)
	if err != nil {
		t.Fatal(err)
	}
	return m
}

func recQueue(t *testing.T, c *Client) []string {
	t.Helper()
	l, err := c.Records()
	if err != nil {
		t.Fatal(err)
	}
	return l
}

// The copy goes on a record_only frame signed to this box, writes no inbox,
// outbox or pending/ file, and leaves no queue file once the hub took it.
func TestRecordSendsRecordOnlyToOwnBox(t *testing.T) {
	h := newFakeHub(t)
	c := hubClient(t, h)
	m := recMsg(t, c, "same box")
	d, err := c.SendRecord(context.Background(), m)
	if err != nil || d != wire.DeliverySent { // the fake hub answers sent to every send
		t.Fatalf("delivery %q err %v", d, err)
	}
	h.mu.Lock()
	recs, envs := append([]bool(nil), h.records...), h.envs
	h.mu.Unlock()
	if len(recs) != 1 || !recs[0] {
		t.Fatalf("record_only on the frames: %v, want [true]", recs)
	}
	env, err := wire.ParseEnvelope(envs[0])
	if err != nil || env.ToBox != "box-a" || env.FromBox != "box-a" {
		t.Fatalf("envelope %+v %v, want box-a to box-a", env, err)
	}
	if q := recQueue(t, c); len(q) != 0 {
		t.Fatalf("record queue after the send: %v", q)
	}
	if p, _ := c.Pending(); len(p) != 0 || c.queued(true) {
		t.Fatalf("pending %v / queued %v after a record send", p, c.queued(true))
	}
	// The session's welcome writes .hub/roster.json; nothing else may exist.
	for _, f := range srFiles(t, c.Cfg.SpoolRoot) {
		if filepath.Base(f) != "roster.json" {
			t.Fatalf("a record wrote a spool file: %s", f)
		}
	}
}

func TestRecordRefusesAttachments(t *testing.T) {
	c := hubClient(t, newFakeHub(t))
	m := recMsg(t, c, "with a file")
	m.Files = []msg.Attachment{{Mode: "ref", Path: "/x", Name: "x"}}
	if _, err := c.SendRecord(context.Background(), m); err == nil {
		t.Fatal("a record with an attachment was sent")
	}
}

// Hub down: pending, the copy waits in the record queue; a box session's
// flush sends it later on a record_only frame and empties the queue.
func TestRecordHubDownQueuesThenFlushes(t *testing.T) {
	h := newFakeHub(t)
	c := hubClient(t, h)
	c.Cfg.HubURL = "http://127.0.0.1:1"
	m := recMsg(t, c, "while down")
	d, err := c.SendRecord(context.Background(), m)
	if err != nil || d != wire.DeliveryPending {
		t.Fatalf("hub down: delivery %q err %v, want pending", d, err)
	}
	if q := recQueue(t, c); len(q) != 1 || !c.queued(true) {
		t.Fatalf("record queue %v, queued %v", q, c.queued(true))
	}
	c.Cfg.HubURL = h.srv.URL
	s := srSession(t, c, wire.RoleBox)
	if n, err := s.Flush(context.Background()); err != nil || n != 1 {
		t.Fatalf("flush %d %v, want 1", n, err)
	}
	h.mu.Lock()
	recs := append([]bool(nil), h.records...)
	h.mu.Unlock()
	if len(recs) != 1 || !recs[0] {
		t.Fatalf("flushed frames record_only %v, want [true]", recs)
	}
	if c.queued(true) {
		t.Fatal("the record queue is not empty after the flush")
	}
}

// A 4xx moves the copy to rejected/ and the flush goes on to the next one; a
// 5xx keeps it queued; an envelope that does not parse is rejected.
func TestRecordRefusals(t *testing.T) {
	h := newFakeHub(t)
	c := hubClient(t, h)
	h.refuse = &wire.Frame{Type: wire.TError, Error: "record_not_local", Status: http.StatusBadRequest}
	if _, err := c.SendRecord(context.Background(), recMsg(t, c, "refused")); err == nil {
		t.Fatal("a 4xx record answered no error")
	}
	if n := srRejected(t, c); n != 1 || len(recQueue(t, c)) != 0 {
		t.Fatalf("rejected %d, queue %v after a 4xx", n, recQueue(t, c))
	}
	h.refuse = &wire.Frame{Type: wire.TError, Error: "internal", Status: http.StatusInternalServerError}
	if d, err := c.SendRecord(context.Background(), recMsg(t, c, "5xx")); err != nil || d != wire.DeliveryPending {
		t.Fatalf("5xx: delivery %q err %v, want pending", d, err)
	}
	if len(recQueue(t, c)) != 1 {
		t.Fatal("a 5xx record left the queue")
	}
	// A broken file first, then the queued one: the broken one is rejected,
	// the flush goes on, and the 5xx stops it with the copy still queued.
	if err := writeAtomic(filepath.Join(c.recordDir(), "00000000T000000Z--broken.json"), []byte("{")); err != nil {
		t.Fatal(err)
	}
	s := srSession(t, c, wire.RoleBox)
	if _, err := s.Flush(context.Background()); err == nil {
		t.Fatal("a flush stopped by a 5xx answered no error")
	}
	if n := srRejected(t, c); n != 2 {
		t.Fatalf("rejected/ holds %d, want 2 (the 4xx and the broken file)", n)
	}
	if len(recQueue(t, c)) != 1 {
		t.Fatal("the 5xx copy left the queue")
	}
}

func TestRecordsListsOnlyEnvelopes(t *testing.T) {
	c := testClient(t)
	if l, err := c.Records(); err != nil || l != nil {
		t.Fatalf("no queue dir: %v %v", l, err)
	}
	if err := os.MkdirAll(filepath.Join(c.recordDir(), "sub"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, n := range []string{"b--2.json", "a--1.json", "a--1.json.reason"} {
		if err := writeAtomic(filepath.Join(c.recordDir(), n), []byte("{}")); err != nil {
			t.Fatal(err)
		}
	}
	l := recQueue(t, c)
	if len(l) != 2 || filepath.Base(l[0]) != "a--1.json" || filepath.Base(l[1]) != "b--2.json" {
		t.Fatalf("records %v, want a--1.json then b--2.json", l)
	}
}

// A box without its key sends nothing and queues nothing.
func TestRecordNeedsTheBoxKey(t *testing.T) {
	c := hubClient(t, newFakeHub(t))
	if err := os.RemoveAll(c.Cfg.KeysDir); err != nil {
		t.Fatal(err)
	}
	if _, err := c.SendRecord(context.Background(), recMsg(t, c, "no key")); err == nil {
		t.Fatal("a record without the box key was sent")
	}
	if c.queued(true) {
		t.Fatal("a record without the box key was queued")
	}
}

// A hub whose welcome lacks record_only (the hub before SPL-6513) is sent no
// record: it would deliver the copy as a second message. The copy stays
// queued, a flush on that hub sends nothing and is no error, and the first
// session on a hub that announces the feature sends it once.
func TestRecordNeverSentToAnOldHub(t *testing.T) {
	h := newFakeHub(t)
	h.oldHub = true
	c := hubClient(t, h)
	d, err := c.SendRecord(context.Background(), recMsg(t, c, "old hub"))
	if err != nil || d != wire.DeliveryPending {
		t.Fatalf("old hub: delivery %q err %v, want pending", d, err)
	}
	s := srSession(t, c, wire.RoleBox)
	if n, err := s.Flush(context.Background()); err != nil || n != 0 {
		t.Fatalf("flush on an old hub: %d %v, want 0 nil", n, err)
	}
	h.mu.Lock()
	sent := len(h.records)
	h.oldHub = false
	h.mu.Unlock()
	if sent != 0 {
		t.Fatalf("an old hub got %d send frames, want 0", sent)
	}
	if q := recQueue(t, c); len(q) != 1 {
		t.Fatalf("record queue %v, want the one copy", q)
	}
	if c.queued(s.takesRecords()) {
		t.Fatal("a session on an old hub counts the record queue: the 10 s scan would flush it every tick")
	}
	s2 := srSession(t, c, wire.RoleBox)
	if n, err := s2.Flush(context.Background()); err != nil || n != 1 {
		t.Fatalf("flush on a new hub: %d %v, want 1", n, err)
	}
	h.mu.Lock()
	recs := append([]bool(nil), h.records...)
	h.mu.Unlock()
	if len(recs) != 1 || !recs[0] || len(recQueue(t, c)) != 0 {
		t.Fatalf("new hub: frames %v queue %v, want one record_only and none left", recs, recQueue(t, c))
	}
}

// The other way round (a box that reconnects from a new hub to an old one,
// a hub rollback): the old session does not inherit the new hub's feature,
// so the next copy is not sent and waits in the queue.
func TestRecordNotSentAfterARollbackToAnOldHub(t *testing.T) {
	h := newFakeHub(t)
	c := hubClient(t, h)
	if d, err := c.SendRecord(context.Background(), recMsg(t, c, "new hub")); err != nil || d != wire.DeliverySent {
		t.Fatalf("new hub: delivery %q err %v, want sent", d, err)
	}
	h.mu.Lock()
	h.oldHub = true
	h.mu.Unlock()
	if d, err := c.SendRecord(context.Background(), recMsg(t, c, "old hub")); err != nil || d != wire.DeliveryPending {
		t.Fatalf("old hub after a new one: delivery %q err %v, want pending", d, err)
	}
	h.mu.Lock()
	sent := len(h.records)
	h.mu.Unlock()
	if sent != 1 || len(recQueue(t, c)) != 1 {
		t.Fatalf("frames %d queue %v, want 1 frame (the new hub's) and the second copy queued", sent, recQueue(t, c))
	}
}

// On a box that only ever sees an old hub the record queue keeps the newest
// recordQueueCap copies and evicts the oldest; spool hub-queue shows it. The
// red control: without trimRecords the queue holds all of them.
func TestRecordQueueIsBounded(t *testing.T) {
	h := newFakeHub(t)
	h.oldHub = true
	c := hubClient(t, h)
	defer func(n int) { recordQueueCap = n }(recordQueueCap)
	recordQueueCap = 3
	for i := range 5 {
		m := recMsg(t, c, "old hub")
		m.TS = fmt.Sprintf("2026-11-25T21:00:0%dZ", i)
		if d, err := c.SendRecord(context.Background(), m); err != nil || d != wire.DeliveryPending {
			t.Fatalf("send %d: delivery %q err %v, want pending", i, d, err)
		}
	}
	q := recQueue(t, c)
	if len(q) != 3 || !strings.HasPrefix(filepath.Base(q[0]), "20261125T210002Z--") {
		t.Fatalf("record queue %v, want the 3 newest (from 21:00:02)", q)
	}
	qh, err := c.QueueHealth()
	if err != nil || qh.Records != 3 {
		t.Fatalf("queue health records %d err %v, want 3", qh.Records, err)
	}
}

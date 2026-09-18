package store

import (
	"context"
	"testing"
	"time"
)

// Viewer reads (view.go): shapes, paging, filters, retention, and that a read
// changes nothing (FR-019). Runs on memory and, with SPOOL_TEST_PG_DSN, Postgres.
func TestViewReads(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)

			if err := s.PutPin(ctx, tid, "box-a", pubkey(), false, now, now); err != nil {
				t.Fatal(err)
			}
			if err := s.PutPin(ctx, tid, "box-b", pubkey(), false, now, now); err != nil {
				t.Fatal(err)
			}
			if err := s.RevokePin(ctx, tid, "box-b", now.Add(time.Second), now); err != nil {
				t.Fatal(err)
			}
			if err := s.SetRoster(ctx, tid, "box-a", []string{"GRK-03", "CLE-07"}, now); err != nil {
				t.Fatal(err)
			}
			if err := s.TouchBox(ctx, tid, "box-a", now); err != nil {
				t.Fatal(err)
			}
			boxes, err := s.ViewBoxes(ctx, tid)
			if err != nil || len(boxes) != 2 {
				t.Fatalf("ViewBoxes: %v %+v", err, boxes)
			}
			if a := boxes[0]; a.BoxID != "box-a" || a.Revoked || len(a.Agents) != 2 || a.Agents[0] != "CLE-07" || !a.LastHelloAt.Equal(now) {
				t.Fatalf("box-a: %+v", a)
			}
			if b := boxes[1]; b.BoxID != "box-b" || !b.Revoked || len(b.Agents) != 0 || !b.LastHelloAt.IsZero() {
				t.Fatalf("box-b: %+v", b)
			}

			t1, t2, t3 := uuid4(), uuid4(), uuid4()
			m1 := msgFor(tid, t1, "box-b", now, now.Add(-3*time.Minute), "e1")
			m1.Msg = []byte(`{"v":1,"body":"first line\nmore"}`)
			m2 := msgFor(tid, t1, "box-a", now, now.Add(-1*time.Minute), "e2")
			m2.Kind, m2.FromID, m2.FromBox, m2.ToID, m2.ToBox = "result", "CLE-07", "box-b", "GRK-03", "box-a"
			m3 := msgFor(tid, t2, "box-b", now, now.Add(-2*time.Minute), "e3")
			m3.FromID, m3.Channel = "GRK-09", "alerts"
			gone := msgFor(tid, t3, "box-b", now, now.Add(-time.Hour), "e4")
			gone.ExpiresAt = now.Add(-time.Minute)
			for _, m := range []Message{m1, m2, m3, gone} {
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
			}
			if err := s.Enqueue(ctx, tid, m1.MsgID, "box-b", now, now.Add(time.Hour), 1000); err != nil {
				t.Fatal(err)
			}

			all, err := s.ViewThreads(ctx, tid, ThreadQuery{Now: now})
			if err != nil || len(all) != 2 || all[0].TaskID != t1 || all[1].TaskID != t2 {
				t.Fatalf("threads (expired excluded, newest first): %v %+v", err, all)
			}
			r := all[0]
			if r.Count != 2 || len(r.Kinds) != 2 || r.Kinds[0] != "task" || r.Kinds[1] != "result" ||
				!r.FirstAt.Equal(m1.ReceivedAt) || !r.LastAt.Equal(m2.ReceivedAt) || len(r.Parties) != 4 ||
				string(r.FirstMsg) == "" {
				t.Fatalf("t1 row: %+v", r)
			}
			page, _ := s.ViewThreads(ctx, tid, ThreadQuery{Now: now, Limit: 1})
			if len(page) != 1 || page[0].TaskID != t1 {
				t.Fatalf("limit 1: %+v", page)
			}
			page, _ = s.ViewThreads(ctx, tid, ThreadQuery{Now: now, BeforeAt: r.LastAt, BeforeTask: r.TaskID})
			if len(page) != 1 || page[0].TaskID != t2 {
				t.Fatalf("before cursor: %+v", page)
			}
			if f, _ := s.ViewThreads(ctx, tid, ThreadQuery{Now: now, Channel: "alerts"}); len(f) != 1 || f[0].TaskID != t2 || f[0].Channel != "alerts" {
				t.Fatalf("channel filter: %+v", f)
			}
			if f, _ := s.ViewThreads(ctx, tid, ThreadQuery{Now: now, Agent: "GRK-09"}); len(f) != 1 || f[0].TaskID != t2 {
				t.Fatalf("agent filter: %+v", f)
			}
			if f, _ := s.ViewThreads(ctx, newTenant(t, s), ThreadQuery{Now: now}); len(f) != 0 {
				t.Fatalf("other tenant sees %d threads", len(f))
			}
			if ch, err := s.ViewChannels(ctx, tid, now); err != nil || len(ch) != 1 || ch[0].Channel != "alerts" || ch[0].Count != 1 {
				t.Fatalf("channels: %v %+v", err, ch)
			}

			before, _ := s.DeliveryState(ctx, tid, m1.MsgID, "box-b")
			msgs, err := s.ViewThread(ctx, tid, ThreadMsgQuery{TaskID: t1, Now: now})
			if err != nil || len(msgs) != 2 || msgs[0].MsgID != m1.MsgID || string(msgs[0].Env) != "e1" {
				t.Fatalf("thread: %v %+v", err, msgs)
			}
			if d := msgs[0].Deliveries; len(d) != 1 || d[0].ToBox != "box-b" || d[0].State != StateQueued {
				t.Fatalf("deliveries: %+v", d)
			}
			if len(msgs[1].Deliveries) != 0 {
				t.Fatalf("m2 has no delivery row: %+v", msgs[1].Deliveries)
			}
			after, _ := s.ViewThread(ctx, tid, ThreadMsgQuery{TaskID: t1, Now: now, AfterAt: msgs[0].ReceivedAt, AfterID: msgs[0].MsgID})
			if len(after) != 1 || after[0].MsgID != m2.MsgID {
				t.Fatalf("after cursor: %+v", after)
			}
			if one, _ := s.ViewThread(ctx, tid, ThreadMsgQuery{TaskID: t1, Now: now, Limit: 1}); len(one) != 1 {
				t.Fatalf("limit: %+v", one)
			}
			// Newest-first windows (chat-reverse): newest, then strictly older.
			desc, _ := s.ViewThread(ctx, tid, ThreadMsgQuery{TaskID: t1, Now: now, Desc: true, Limit: 1})
			if len(desc) != 1 || desc[0].MsgID != m2.MsgID {
				t.Fatalf("desc newest: %+v", desc)
			}
			older, _ := s.ViewThread(ctx, tid, ThreadMsgQuery{TaskID: t1, Now: now, Desc: true, BeforeAt: desc[0].ReceivedAt, BeforeID: desc[0].MsgID})
			if len(older) != 1 || older[0].MsgID != m1.MsgID || len(older[0].Deliveries) != 1 {
				t.Fatalf("desc before cursor: %+v", older)
			}
			if none, _ := s.ViewThread(ctx, tid, ThreadMsgQuery{TaskID: t3, Now: now}); len(none) != 0 {
				t.Fatalf("expired thread visible: %+v", none)
			}

			// FR-019: reading changed nothing.
			if st, _ := s.DeliveryState(ctx, tid, m1.MsgID, "box-b"); st != before || st != StateQueued {
				t.Fatalf("state %q -> %q after reads", before, st)
			}
			if q, _ := s.QueuedFor(ctx, tid, "box-b", now); len(q) != 1 || q[0].MsgID != m1.MsgID {
				t.Fatalf("queue drained by a read: %+v", q)
			}
			if again, _ := s.ViewBoxes(ctx, tid); !again[0].LastHelloAt.Equal(now) {
				t.Fatalf("last_hello_at moved: %+v", again[0])
			}
		})
	}
}

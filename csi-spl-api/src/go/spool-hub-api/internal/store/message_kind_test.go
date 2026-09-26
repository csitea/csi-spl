package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// SPL-952: SetKind makes the new kind the message's current kind, keeps the
// envelope as sent, appends to the register, and every view read carries the
// override; setting the same kind records nothing.
func TestSetKind(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			task := uuid4()
			m := msgFor(tid, task, "box-b", now, now, `{"e":1}`)
			if _, err := s.InsertMessage(ctx, m); err != nil {
				t.Fatal(err)
			}
			views := func() ViewMsg {
				t.Helper()
				got, err := s.ViewTopic(ctx, tid, TopicMsgQuery{TaskID: task, Limit: 10, Now: now})
				if err != nil || len(got) != 1 {
					t.Fatalf("view: %v %d", err, len(got))
				}
				if b, ok := s.(TopicsMessager); ok {
					batch, _, err := b.ViewTopicsMessages(ctx, tid, TopicsMsgQuery{TaskIDs: []string{task}, PerTopic: 5, Now: now})
					if err != nil || len(batch[task]) != 1 {
						t.Fatalf("batch view: %v %v", err, batch)
					}
					if bv := batch[task][0]; bv.Kind != got[0].Kind || !bv.KindSetAt.Equal(got[0].KindSetAt) || bv.KindSetBy != got[0].KindSetBy {
						t.Fatalf("batch %+v vs single %+v", bv, got[0])
					}
				}
				return got[0]
			}
			if v := views(); v.Kind != "" || !v.KindSetAt.IsZero() {
				t.Fatalf("an unchanged message carries an override: %+v", v)
			}
			at := now.Add(time.Second)
			c, err := s.SetKind(ctx, tid, m.MsgID, "blocker", "HUM-1", at)
			if err != nil || c.Seq != 1 || c.From != "task" || c.To != "blocker" {
				t.Fatalf("SetKind: %+v %v", c, err)
			}
			if v := views(); v.Kind != "blocker" || v.KindSetBy != "HUM-1" || !v.KindSetAt.Equal(at) || string(v.Env) != `{"e":1}` {
				t.Fatalf("view after SetKind: %+v", v)
			}
			if e, _ := s.GetEditable(ctx, tid, m.MsgID, now); e.Kind != "blocker" || e.KindSetBy != "HUM-1" {
				t.Fatalf("GetEditable: kind %q by %q", e.Kind, e.KindSetBy)
			}
			if c, err := s.SetKind(ctx, tid, m.MsgID, "blocker", "HUM-2", at); err != nil || c.Seq != 0 {
				t.Fatalf("same kind again: %+v %v", c, err)
			}
			if c, err := s.SetKind(ctx, tid, m.MsgID, "note", "HUM-2", at.Add(time.Second)); err != nil || c.Seq != 2 || c.From != "blocker" {
				t.Fatalf("second change: %+v %v", c, err)
			}
			if cs, _ := s.KindChanges(ctx, tid, m.MsgID); len(cs) != 2 || cs[0].To != "blocker" || cs[1].To != "note" {
				t.Fatalf("register: %+v", cs)
			}
			if _, err := s.SetKind(ctx, newTenant(t, s), m.MsgID, "task", "HUM-1", at); !errors.Is(err, ErrNotFound) {
				t.Fatalf("another tenant's message: %v", err)
			}
		})
	}
}

package store

import (
	"context"
	"reflect"
	"testing"
	"time"
)

// Spec 067 L3 (rdb 0112): messages.ref_task_id and messages.mirror_of go in
// with the insert and come back on both view reads, NULL when unset. Run on
// Memory and Postgres. Controls: drop a column from the insert and the round
// trip reads ""; drop it from one scan and the batch differs from ViewTopic;
// drop the CHECK and a row that mirrors itself is stored.
func TestDMRefTaskRoundTrip(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid, other := newTenant(t, s), newTenant(t, s)
			task, topic := uuid4(), uuid4()

			dm := msgFor(tid, task, "box-b", now, now, `{"e":"dm"}`)
			dm.RefTaskID = topic
			copied := msgFor(tid, task, "box-b", now.Add(time.Second), now.Add(time.Second), `{"e":"copy"}`)
			copied.MirrorOf = dm.MsgID
			plain := msgFor(tid, task, "box-b", now.Add(2*time.Second), now.Add(2*time.Second), `{"e":"plain"}`)
			for _, m := range []Message{dm, copied, plain} {
				if ok, err := s.InsertMessage(ctx, m); err != nil || !ok {
					t.Fatalf("insert %s: %v %v", m.Env, ok, err)
				}
			}
			// the identical resend is still a no-op, not a conflict
			if ok, err := s.InsertMessage(ctx, dm); err != nil || ok {
				t.Fatalf("resend: %v %v", ok, err)
			}

			got, err := s.ViewTopic(ctx, tid, TopicMsgQuery{TaskID: task, Limit: 10, Now: now})
			if err != nil || len(got) != 3 {
				t.Fatalf("view: %v %d", err, len(got))
			}
			want := [][2]string{{topic, ""}, {"", dm.MsgID}, {"", ""}}
			for i, v := range got {
				if [2]string{v.RefTaskID, v.MirrorOf} != want[i] {
					t.Fatalf("row %d (%s): ref_task_id %q mirror_of %q, want %q", i, v.Env, v.RefTaskID, v.MirrorOf, want[i])
				}
			}

			// RLS unchanged: another tenant reads none of it
			if leak, err := s.ViewTopic(ctx, other, TopicMsgQuery{TaskID: task, Limit: 10, Now: now}); err != nil || len(leak) != 0 {
				t.Fatalf("other tenant: %v %d", err, len(leak))
			}

			if b, ok := s.(TopicsMessager); ok {
				desc, err := s.ViewTopic(ctx, tid, TopicMsgQuery{TaskID: task, Limit: 10, Now: now, Desc: true})
				if err != nil {
					t.Fatal(err)
				}
				batch, _, err := b.ViewTopicsMessages(ctx, tid, TopicsMsgQuery{TaskIDs: []string{task}, PerTopic: 10, Now: now})
				if err != nil {
					t.Fatal(err)
				}
				if !reflect.DeepEqual(batch[task], desc) {
					t.Fatalf("batch and single differ:\n batch %+v\nsingle %+v", batch[task], desc)
				}
			}

			if _, ok := s.(*Postgres); ok {
				self := msgFor(tid, task, "box-b", now, now, `{"e":"self"}`)
				self.MirrorOf = self.MsgID
				if _, err := s.InsertMessage(ctx, self); err == nil {
					t.Fatal("a row that mirrors itself was stored")
				}
				bad := msgFor(tid, task, "box-b", now, now, `{"e":"bad"}`)
				bad.RefTaskID = "not-a-uuid"
				if _, err := s.InsertMessage(ctx, bad); err == nil {
					t.Fatal("a non-uuid ref_task_id was stored")
				}
			}
		})
	}
}

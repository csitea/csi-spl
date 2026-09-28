package store

import (
	"context"
	"reflect"
	"testing"
	"time"
)

// TestViewTopicAndBatchAgree pins that the single-topic read (ViewTopic,
// newest first) and the card batch (ViewTopicsMessages) answer the SAME rows
// field for field: edited (with its revision), kind override, a plain one,
// and their reactions. Recorded before the two scans were folded into one
// (SPL-1029 round 2).
func TestViewTopicAndBatchAgree(t *testing.T) {
	for name, s := range drivers(t) {
		b, ok := s.(TopicsMessager)
		if !ok {
			continue
		}
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			task := uuid4()
			var ids []string
			for i := 0; i < 3; i++ {
				at := now.Add(time.Duration(i) * time.Second)
				m := msgFor(tid, task, "box-b", at, at, `{"e":1}`)
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				ids = append(ids, m.MsgID)
			}
			if _, err := s.ApplyEdit(ctx, tid, ids[0], Edit{Body: "edited", Msg: []byte(`{"v":1}`), Env: []byte(`{"e":2}`),
				EditedBy: "HUM-1", EditedAt: now.Add(time.Minute)}); err != nil {
				t.Fatal(err)
			}
			if _, err := s.SetKind(ctx, tid, ids[1], "blocker", "HUM-2", now.Add(2*time.Minute)); err != nil {
				t.Fatal(err)
			}
			if err := s.AddReaction(ctx, tid, ids[2], "HUM-1", "👍", now); err != nil {
				t.Fatal(err)
			}
			single, err := s.ViewTopic(ctx, tid, TopicMsgQuery{TaskID: task, Limit: 10, Now: now, Desc: true})
			if err != nil || len(single) != 3 {
				t.Fatalf("single: %v %d", err, len(single))
			}
			batch, react, err := b.ViewTopicsMessages(ctx, tid, TopicsMsgQuery{TaskIDs: []string{task}, PerTopic: 10, Now: now})
			if err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(batch[task], single) {
				t.Fatalf("batch and single differ:\n batch %+v\nsingle %+v", batch[task], single)
			}
			if single[2].Revision == 0 || single[2].EditedBy != "HUM-1" || single[1].Kind != "blocker" || len(react[ids[2]]) != 1 {
				t.Fatalf("fixture not exercised: %+v react %v", single, react)
			}
		})
	}
}

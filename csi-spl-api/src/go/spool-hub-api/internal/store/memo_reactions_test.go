package store

import (
	"context"
	"reflect"
	"testing"
	"time"
)

// SPL-1121: inside a request memo, ViewTopic reads the page's reactions in
// its deliveries batch and ReactionsFor answers from it - the same map the
// database answers, messages without a reaction included. The memo dies with
// the request: CONTROL, a reaction added afterwards is seen by the next
// request and by any read without a memo; ids the memo did not read go to the
// database.
func TestViewTopicMemoCarriesReactions(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tid := newTenant(t, s)
			task := uuid4()
			var ids []string
			for i := 0; i < 3; i++ {
				m := Message{TenantID: tid, MsgID: uuid4(), TaskID: task, Channel: "tasks", TS: now,
					FromBox: "box-a", FromID: "CLE-07", ToBox: "box-b", ToID: "GRK-03", Kind: "note", Body: "b",
					Files: []byte("[]"), Msg: []byte(`{"v":1}`), EnvSig: "sig", Env: []byte("env-" + uuid4()),
					ReceivedAt: now.Add(time.Duration(i) * time.Second), ExpiresAt: now.Add(time.Hour)}
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				ids = append(ids, m.MsgID)
			}
			for _, r := range []struct{ id, actor, emoji string }{{ids[0], "HUM-1", "👍"}, {ids[0], "HUM-2", "🎉"}, {ids[2], "HUM-1", "👀"}} {
				if err := s.AddReaction(ctx, tid, r.id, r.actor, r.emoji, now); err != nil {
					t.Fatal(err)
				}
			}
			want, err := s.ReactionsFor(ctx, tid, ids) // no memo: the database
			if err != nil || len(want) != 2 {
				t.Fatalf("reactions %v %v", want, err)
			}

			req := WithMemo(ctx)
			rows, err := s.ViewTopic(req, tid, TopicMsgQuery{TaskID: task, Limit: 10, Now: now})
			if err != nil || len(rows) != 3 {
				t.Fatalf("topic %d rows %v", len(rows), err)
			}
			got, err := s.ReactionsFor(req, tid, ids)
			if err != nil || !reflect.DeepEqual(got, want) {
				t.Fatalf("memo reactions %v %v, database %v", got, err, want)
			}

			if err := s.AddReaction(ctx, tid, ids[1], "HUM-3", "✅", now.Add(time.Second)); err != nil {
				t.Fatal(err)
			}
			fresh, _ := s.ReactionsFor(ctx, tid, ids)
			if len(fresh) != 3 {
				t.Fatalf("new reaction not stored: %v", fresh)
			}
			next := WithMemo(ctx) // the next request
			if _, err := s.ViewTopic(next, tid, TopicMsgQuery{TaskID: task, Limit: 10, Now: now}); err != nil {
				t.Fatal(err)
			}
			if got, _ := s.ReactionsFor(next, tid, ids); !reflect.DeepEqual(got, fresh) {
				t.Fatalf("next request's memo %v, database %v", got, fresh)
			}
			// An id the memo did not read (another topic) goes to the database.
			other := uuid4()
			if got, err := s.ReactionsFor(next, tid, append(ids[:1:1], other)); err != nil || len(got) != 1 {
				t.Fatalf("partly unread ids %v %v", got, err)
			}
		})
	}
}

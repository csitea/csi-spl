package store

import (
	"context"
	"errors"
	"sort"
	"testing"
	"time"
)

// 8f588edd: a promote splits one reply out of its topic into a NEW topic of its
// own - the reply becomes the opening card (is_parent 1) of a fresh task in the
// same channel, its sub-thread moves with it (parents repointed), the source
// topic keeps the rest, received_at is untouched, and the home is recorded so
// an undo re-seats the reply and takes every moved row back.
func TestPromoteMessage(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			at := func(n int) time.Time { return now.Add(time.Duration(n) * time.Second) }
			put := func(task, parent, channel string, isParent, n int) Message {
				t.Helper()
				m := msgFor(tid, task, "box-b", at(n), at(n), `{"n":"`+uuid4()+`"}`)
				m.ParentTaskID, m.IsParent, m.Channel = parent, isParent, channel
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}
			row := func(id string) EditableMessage {
				t.Helper()
				m, err := s.GetEditable(ctx, tid, id, now)
				if err != nil {
					t.Fatalf("read %s: %v", id, err)
				}
				return m
			}
			parent := func(id string) int {
				t.Helper()
				st, err := s.CardState(ctx, tid, id, now)
				if err != nil {
					t.Fatalf("card state %s: %v", id, err)
				}
				return st.IsParent
			}
			walk := func(card, own string) map[string]bool {
				t.Helper()
				set, err := s.TopicOf(ctx, tid, card, own)
				if err != nil {
					t.Fatal(err)
				}
				out := map[string]bool{}
				for _, id := range set.MsgIDs {
					out[id] = true
				}
				return out
			}
			T, N := uuid4(), uuid4()
			c := put(T, "", "devel", 1, 0)        // T's card
			r1 := put(T, "", "devel", 0, 1)       // the reply we promote
			r2 := put(T, "", "devel", 0, 2)       // a reply that stays
			x1 := put(r1.MsgID, T, "devel", 0, 3) // a sub-thread hung on r1
			x2 := put(r1.MsgID, T, "devel", 0, 4) // a second sub-thread row on r1

			// A promote into a task inside the message's own thread is a cycle.
			if _, err := s.PromoteMessage(ctx, tid, r1.MsgID, T, r1.MsgID, "HUM-1", at(20)); !errors.Is(err, ErrMoveCycle) {
				t.Fatalf("promote into its own thread: %v", err)
			}
			if _, err := s.PromoteMessage(ctx, tid, uuid4(), T, N, "HUM-1", at(20)); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown source row: %v", err)
			}

			// Promote r1 into N.
			res, err := s.PromoteMessage(ctx, tid, r1.MsgID, T, N, "HUM-1", at(20))
			if err != nil || len(res.MsgIDs) != 3 || res.MsgIDs[0] != r1.MsgID || !res.Moved || !res.ReceivedAt.Equal(r1.ReceivedAt) {
				t.Fatalf("promote: %+v %v", res, err)
			}
			// r1 is now the card of N, its channel and timestamp untouched, the
			// home recorded for the undo.
			if m := row(r1.MsgID); m.TaskID != N || parent(r1.MsgID) != 1 || m.ParentTaskID != "" || m.Channel != "devel" ||
				m.Move.FromTask != T || m.Move.FromChannel != "devel" || !m.Move.Moved() || !m.ReceivedAt.Equal(r1.ReceivedAt) {
				t.Fatalf("promoted card: %+v", m)
			}
			// Its sub-thread rows keep their own task but are repointed onto N,
			// and carry NO move mark (the channel did not change).
			for _, id := range []string{x1.MsgID, x2.MsgID} {
				if m := row(id); m.TaskID != r1.MsgID || m.ParentTaskID != N || m.Channel != "devel" || m.Move.Moved() {
					t.Fatalf("sub-thread %s after promote: %+v", id, m)
				}
			}
			// The source topic keeps its card and the other reply, unmarked.
			for _, id := range []string{c.MsgID, r2.MsgID} {
				if m := row(id); m.TaskID != T || m.Move.Moved() {
					t.Fatalf("source row %s touched by the promote: %+v", id, m)
				}
			}
			// The new topic is archivable at once: its card is is_parent 1, first.
			if tc, err := s.TaskCard(ctx, tid, N, now); err != nil || tc.MsgID != r1.MsgID {
				t.Fatalf("new topic card: %+v %v", tc, err)
			}
			if st, err := s.CardState(ctx, tid, r1.MsgID, now); err != nil || st.IsParent != 1 || !st.FirstOfTask {
				t.Fatalf("new card state (e802196b control): %+v %v", st, err)
			}
			// N walks r1 and its sub-thread; T no longer walks them.
			if got := walk(r1.MsgID, N); !got[r1.MsgID] || !got[x1.MsgID] || !got[x2.MsgID] {
				t.Fatalf("N does not walk the promoted thread: %v", got)
			}
			if got := walk(c.MsgID, T); got[r1.MsgID] || got[x1.MsgID] || !got[c.MsgID] || !got[r2.MsgID] {
				t.Fatalf("T still walks the promoted thread: %v", got)
			}

			// Undo: r1 home as a reply, its thread repointed back onto T.
			if err := s.DemoteTopic(ctx, tid, r1.MsgID, res.MsgIDs); err != nil {
				t.Fatalf("demote: %v", err)
			}
			if m := row(r1.MsgID); m.TaskID != T || parent(r1.MsgID) != 0 || m.Channel != "devel" || m.Move.Moved() {
				t.Fatalf("reply after undo: %+v", m)
			}
			for _, id := range []string{x1.MsgID, x2.MsgID} {
				if m := row(id); m.TaskID != r1.MsgID || m.ParentTaskID != T || m.Channel != "devel" || m.Move.Moved() {
					t.Fatalf("sub-thread %s after undo: %+v", id, m)
				}
			}
			if tc, err := s.TaskCard(ctx, tid, T, now); err != nil || tc.MsgID != c.MsgID {
				t.Fatalf("source card after undo: %+v %v", tc, err)
			}
			got := []string{}
			for id := range walk(c.MsgID, T) {
				got = append(got, id)
			}
			want := []string{c.MsgID, r1.MsgID, r2.MsgID, x1.MsgID, x2.MsgID}
			sort.Strings(got)
			sort.Strings(want)
			if len(got) != len(want) {
				t.Fatalf("T after undo: %v, want %v", got, want)
			}
			for i := range want {
				if got[i] != want[i] {
					t.Fatalf("T after undo: %v, want %v", got, want)
				}
			}

			// Another tenant sees nothing.
			if _, err := s.PromoteMessage(ctx, newTenant(t, s), r1.MsgID, T, N, "HUM-1", at(50)); !errors.Is(err, ErrNotFound) {
				t.Fatalf("another tenant's row: %v", err)
			}
		})
	}
}

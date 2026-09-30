package store

import (
	"context"
	"errors"
	"sort"
	"testing"
	"time"
)

// 714c7028: a topic merge folds every row of the source topic into the target
// task, demotes the source opener to a reply, keeps the target's opener as the
// card even when the source is older, leaves received_at untouched, and records
// the home so an undo puts the topic back and re-seats its card.
func TestMergeTopic(t *testing.T) {
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
			T, U, S := uuid4(), uuid4(), uuid4()
			c := put(T, "", "devel", 1, 0)        // T's card, OLDER than U's
			r1 := put(T, "", "devel", 0, 1)       // replies
			r2 := put(T, "", "devel", 0, 2)       //
			x1 := put(r1.MsgID, T, "devel", 0, 3) // a thread on r1
			s1 := put(S, T, "devel", 1, 4)        // a sub-task of T
			d := put(U, "", "ops", 1, 5)          // the target topic's card
			du := put(U, "", "ops", 0, 6)         // and a reply in it

			// Merge a topic into itself or into a task inside it is refused.
			if _, err := s.MergeTopic(ctx, tid, c.MsgID, T, r1.MsgID, "ops", "HUM-1", at(20)); !errors.Is(err, ErrMergeCycle) {
				t.Fatalf("merge into its own thread: %v", err)
			}
			if _, err := s.MergeTopic(ctx, tid, uuid4(), T, U, "ops", "HUM-1", at(20)); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown source card: %v", err)
			}

			// Merge T into U.
			res, err := s.MergeTopic(ctx, tid, c.MsgID, T, U, "ops", "HUM-1", at(20))
			if err != nil || len(res.MsgIDs) != 5 || res.MsgIDs[0] != c.MsgID || !res.At.Equal(c.ReceivedAt) {
				t.Fatalf("merge: %+v %v", res, err)
			}
			// The opener is now a normal reply under U, its timestamp untouched.
			if m := row(c.MsgID); m.TaskID != U || parent(c.MsgID) != 0 || m.ParentTaskID != "" || m.Channel != "ops" ||
				m.Move.FromTask != T || m.Move.FromChannel != "devel" || !m.ReceivedAt.Equal(c.ReceivedAt) {
				t.Fatalf("opener after merge: %+v", m)
			}
			for _, id := range []string{r1.MsgID, r2.MsgID} {
				if m := row(id); m.TaskID != U || parent(id) != 0 || m.Channel != "ops" || m.Move.FromTask != T {
					t.Fatalf("top-level reply %s after merge: %+v", id, m)
				}
			}
			// A thread keeps its own task but is repointed off T onto U.
			if x := row(x1.MsgID); x.TaskID != r1.MsgID || x.ParentTaskID != U || x.Channel != "ops" || x.Move.FromParent != T {
				t.Fatalf("thread after merge: %+v", x)
			}
			// A sub-task keeps its card bit and its own task; only its parent moves.
			if m := row(s1.MsgID); m.TaskID != S || m.ParentTaskID != U || parent(s1.MsgID) != 1 || m.Channel != "ops" {
				t.Fatalf("sub-task after merge: %+v", m)
			}
			// The target's opener stays the card though the source rows are older.
			if tc, err := s.TaskCard(ctx, tid, U, now); err != nil || tc.MsgID != d.MsgID {
				t.Fatalf("target card unseated by an older merged row: %+v %v", tc, err)
			}
			if ch, _ := s.TopicChannel(ctx, tid, U); ch != "ops" {
				t.Fatalf("target topic channel: %q", ch)
			}
			// The merged topic is still archivable: its card is is_parent=1, first.
			if st, err := s.CardState(ctx, tid, d.MsgID, now); err != nil || st.IsParent != 1 || !st.FirstOfTask {
				t.Fatalf("target card state (e802196b control): %+v %v", st, err)
			}
			// U now walks every merged row; T walks none of them.
			if got := walk(d.MsgID, U); !got[c.MsgID] || !got[r1.MsgID] || !got[r2.MsgID] || !got[x1.MsgID] || !got[s1.MsgID] || !got[du.MsgID] {
				t.Fatalf("U does not walk the merged topic: %v", got)
			}
			if got := walk(c.MsgID, T); len(got) != 1 || !got[c.MsgID] {
				t.Fatalf("T still walks merged rows: %v", got)
			}

			// Undo: every row home, the source opener re-seated as the card.
			if err := s.UnmergeTopic(ctx, tid, c.MsgID, res.MsgIDs); err != nil {
				t.Fatalf("unmerge: %v", err)
			}
			if m := row(c.MsgID); m.TaskID != T || parent(c.MsgID) != 1 || m.Channel != "devel" || m.Move.Moved() {
				t.Fatalf("opener after undo: %+v", m)
			}
			for _, id := range []string{r1.MsgID, r2.MsgID} {
				if m := row(id); m.TaskID != T || m.Channel != "devel" || m.Move.Moved() {
					t.Fatalf("reply %s after undo: %+v", id, m)
				}
			}
			if x := row(x1.MsgID); x.TaskID != r1.MsgID || x.ParentTaskID != T || x.Channel != "devel" || x.Move.Moved() {
				t.Fatalf("thread after undo: %+v", x)
			}
			if m := row(s1.MsgID); m.TaskID != S || m.ParentTaskID != T || m.Channel != "devel" {
				t.Fatalf("sub-task after undo: %+v", m)
			}
			if tc, err := s.TaskCard(ctx, tid, T, now); err != nil || tc.MsgID != c.MsgID || tc.Channel != "devel" {
				t.Fatalf("source card not restored: %+v %v", tc, err)
			}
			got := []string{}
			for id := range walk(c.MsgID, T) {
				got = append(got, id)
			}
			want := []string{c.MsgID, r1.MsgID, r2.MsgID, x1.MsgID, s1.MsgID}
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
			if _, err := s.MergeTopic(ctx, newTenant(t, s), c.MsgID, T, U, "ops", "HUM-1", at(50)); !errors.Is(err, ErrNotFound) {
				t.Fatalf("another tenant's card: %v", err)
			}
		})
	}
}

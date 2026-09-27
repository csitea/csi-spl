package store

import (
	"context"
	"errors"
	"sort"
	"testing"
	"time"
)

// SPL-1024 (specs/045): a topic move re-channels every row of the topic and
// nothing else; a message move re-homes the row and takes its own thread; a
// move back home clears the mark; a second move keeps the first home.
func TestMoveTopicAndMessage(t *testing.T) {
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
			T, U, S, V := uuid4(), uuid4(), uuid4(), uuid4()
			c := put(T, "", "devel", 1, 0)        // T's card
			r1 := put(T, "", "devel", 0, 1)       // replies
			r2 := put(T, "", "devel", 0, 2)       //
			x1 := put(r1.MsgID, T, "devel", 0, 3) // a thread on r1
			s1 := put(S, T, "devel", 1, 4)        // a sub-task of T
			d := put(U, "", "ops", 1, 5)          // another topic
			du := put(U, "", "ops", 0, 6)         //
			v := put(V, "", "ops", 1, 7)          // a third
			if err := s.AddReaction(ctx, tid, r1.MsgID, "HUM-1", "👍", now); err != nil {
				t.Fatal(err)
			}

			// TaskCard: a task's first row, level 1 only.
			if tc, err := s.TaskCard(ctx, tid, U, now); err != nil || tc.MsgID != d.MsgID || tc.Channel != "ops" || !tc.ReceivedAt.Equal(d.ReceivedAt) {
				t.Fatalf("task card: %+v %v", tc, err)
			}
			if _, err := s.TaskCard(ctx, tid, r1.MsgID, now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("a thread whose first row is a reply is not a card: %v", err)
			}
			if _, err := s.TaskCard(ctx, tid, uuid4(), now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown task: %v", err)
			}
			if _, ok, err := s.MovedTaskChannel(ctx, tid, T); ok || err != nil {
				t.Fatalf("nothing moved yet: %v %v", ok, err)
			}

			// 1. Move topic T to ops: its five rows, nothing else.
			res, err := s.MoveTopic(ctx, tid, c.MsgID, T, "ops", "HUM-1", at(20))
			if err != nil || !res.Moved || len(res.MsgIDs) != 5 || res.MsgIDs[0] != c.MsgID {
				t.Fatalf("move topic: %+v %v", res, err)
			}
			for _, id := range []string{c.MsgID, r1.MsgID, r2.MsgID, x1.MsgID, s1.MsgID} {
				m := row(id)
				if m.Channel != "ops" || !m.Move.At.Equal(at(20)) || m.Move.By != "HUM-1" || m.Move.FromChannel != "devel" || m.Move.FromTask != "" {
					t.Fatalf("moved row %s: channel %q mark %+v", id, m.Channel, m.Move)
				}
			}
			if m := row(d.MsgID); m.Move.Moved() || m.Channel != "ops" {
				t.Fatalf("a row outside the topic was marked: %+v", m.Move)
			}
			if ch, _ := s.TopicChannel(ctx, tid, T); ch != "ops" {
				t.Fatalf("topic channel after the move: %q", ch)
			}
			if ch, ok, err := s.MovedTaskChannel(ctx, tid, T); ch != "ops" || !ok || err != nil {
				t.Fatalf("moved task channel: %q %v %v", ch, ok, err)
			}
			if _, ok, _ := s.MovedTaskChannel(ctx, tid, U); ok {
				t.Fatal("an unmoved task read as moved")
			}
			view, err := s.ViewTopic(ctx, tid, TopicMsgQuery{TaskID: T, Limit: 10, Now: now})
			if err != nil || len(view) != 3 {
				t.Fatalf("view: %v %d", err, len(view))
			}
			for _, vm := range view {
				if vm.Move.Channel != "ops" || vm.Move.TaskID != T || vm.Move.FromChannel != "devel" {
					t.Fatalf("view mark: %+v", vm.Move)
				}
			}
			if rs, _ := s.ReactionsFor(ctx, tid, []string{r1.MsgID}); len(rs[r1.MsgID]) != 1 {
				t.Fatalf("a reaction did not stay with its row: %v", rs)
			}

			// 2. A second move keeps the home; a move home clears the mark.
			if _, err := s.MoveTopic(ctx, tid, c.MsgID, T, "alerts", "HUM-2", at(21)); err != nil {
				t.Fatal(err)
			}
			if m := row(r2.MsgID); m.Move.FromChannel != "devel" || m.Move.By != "HUM-2" || m.Channel != "alerts" {
				t.Fatalf("second move: %+v", m.Move)
			}
			res, err = s.MoveTopic(ctx, tid, c.MsgID, T, "devel", "HUM-1", at(22))
			if err != nil || res.Moved {
				t.Fatalf("move home: %+v %v", res, err)
			}
			for _, id := range []string{c.MsgID, r1.MsgID, x1.MsgID, s1.MsgID} {
				if m := row(id); m.Move.Moved() || m.Channel != "devel" {
					t.Fatalf("home row %s still marked: %+v", id, m.Move)
				}
			}
			if _, ok, _ := s.MovedTaskChannel(ctx, tid, T); ok {
				t.Fatal("a topic back home still reads as moved")
			}

			// 3. Move r1 (and its thread x1) into U: under U's card, out of T.
			notBefore := d.ReceivedAt.Add(time.Millisecond)
			if _, err := s.MoveMessage(ctx, tid, r1.MsgID, r1.MsgID, "ops", "HUM-1", at(30), notBefore); !errors.Is(err, ErrMoveCycle) {
				t.Fatalf("into its own thread: %v", err)
			}
			res, err = s.MoveMessage(ctx, tid, r1.MsgID, U, "ops", "HUM-1", at(30), notBefore)
			if err != nil || !res.Moved || len(res.MsgIDs) != 2 || res.MsgIDs[0] != r1.MsgID || !res.ReceivedAt.Equal(notBefore) {
				t.Fatalf("move message: %+v %v", res, err)
			}
			m := row(r1.MsgID)
			if m.TaskID != U || m.ParentTaskID != "" || m.Channel != "ops" || m.Move.FromTask != T || m.Move.FromChannel != "devel" || !m.ReceivedAt.Equal(notBefore) {
				t.Fatalf("moved row: %+v", m)
			}
			if x := row(x1.MsgID); x.TaskID != r1.MsgID || x.ParentTaskID != U || x.Channel != "ops" || x.Move.FromTask != "" || !x.Move.Moved() {
				t.Fatalf("its thread: %+v", x)
			}
			if got := walk(c.MsgID, T); got[r1.MsgID] || got[x1.MsgID] || !got[r2.MsgID] || !got[s1.MsgID] {
				t.Fatalf("T still walks the moved rows: %v", got)
			}
			if got := walk(d.MsgID, U); !got[r1.MsgID] || !got[x1.MsgID] || !got[du.MsgID] {
				t.Fatalf("U does not walk the moved rows: %v", got)
			}
			view, _ = s.ViewTopic(ctx, tid, TopicMsgQuery{TaskID: U, Limit: 10, Now: now})
			if len(view) != 3 || view[0].MsgID != d.MsgID || view[1].MsgID != r1.MsgID || view[1].Move.FromTask != T || view[1].Move.TaskID != U {
				t.Fatalf("U after the move: %+v", view)
			}

			// 4. r1 on to V keeps home T; back to T clears it and its thread.
			if _, err := s.MoveMessage(ctx, tid, r1.MsgID, V, "ops", "HUM-2", at(31), v.ReceivedAt.Add(time.Millisecond)); err != nil {
				t.Fatal(err)
			}
			if m := row(r1.MsgID); m.TaskID != V || m.Move.FromTask != T || m.Move.FromChannel != "devel" {
				t.Fatalf("second message move: %+v", m)
			}
			if x := row(x1.MsgID); x.ParentTaskID != V {
				t.Fatalf("its thread's parent: %+v", x)
			}
			res, err = s.MoveMessage(ctx, tid, r1.MsgID, T, "devel", "HUM-1", at(32), c.ReceivedAt.Add(time.Millisecond))
			if err != nil || res.Moved {
				t.Fatalf("message home: %+v %v", res, err)
			}
			if m := row(r1.MsgID); m.TaskID != T || m.ParentTaskID != "" || m.Channel != "devel" || m.Move.Moved() {
				t.Fatalf("home row: %+v", m)
			}
			if x := row(x1.MsgID); x.ParentTaskID != T || x.Channel != "devel" || x.Move.Moved() {
				t.Fatalf("home thread: %+v", x)
			}
			got := []string{}
			for id := range walk(c.MsgID, T) {
				got = append(got, id)
			}
			sort.Strings(got)
			want := []string{c.MsgID, r1.MsgID, r2.MsgID, x1.MsgID, s1.MsgID}
			sort.Strings(want)
			if len(got) != len(want) {
				t.Fatalf("T after the round trip: %v, want %v", got, want)
			}
			for i := range want {
				if got[i] != want[i] {
					t.Fatalf("T after the round trip: %v, want %v", got, want)
				}
			}

			// 5. A thread row moved home restores its home parent.
			res, err = s.MoveMessage(ctx, tid, x1.MsgID, U, "ops", "HUM-1", at(40), notBefore)
			if err != nil || !res.Moved {
				t.Fatalf("thread row move: %+v %v", res, err)
			}
			if x := row(x1.MsgID); x.TaskID != U || x.ParentTaskID != "" || x.Move.FromTask != r1.MsgID {
				t.Fatalf("thread row moved: %+v", x)
			}
			if _, err := s.MoveMessage(ctx, tid, x1.MsgID, r1.MsgID, "devel", "HUM-1", at(41), time.Time{}); err != nil {
				t.Fatal(err)
			}
			if x := row(x1.MsgID); x.TaskID != r1.MsgID || x.ParentTaskID != T || x.Move.Moved() {
				t.Fatalf("thread row home: %+v", x)
			}

			// Another tenant sees nothing.
			if _, err := s.MoveTopic(ctx, newTenant(t, s), c.MsgID, T, "ops", "HUM-1", at(50)); !errors.Is(err, ErrNotFound) {
				t.Fatalf("another tenant's topic: %v", err)
			}
		})
	}
}

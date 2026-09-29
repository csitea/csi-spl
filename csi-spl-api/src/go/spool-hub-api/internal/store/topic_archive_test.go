package store

import (
	"context"
	"errors"
	"sort"
	"testing"
	"time"
)

// SPL-983 (specs/041): archive hides a card's topic from every list and
// search and keeps it readable by task id; unarchive brings it back; delete
// removes the card and every child - replies, a message-rooted thread, a
// sub-task - with their reactions, revisions, kind changes and deliveries,
// and nothing else. A lobby card hides / deletes itself and its thread,
// never the lobby.
func TestTopicArchiveAndDelete(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			at := func(n int) time.Time { return now.Add(time.Duration(n) * time.Second) }
			put := func(task, parent string, isParent, n int) Message {
				t.Helper()
				m := msgFor(tid, task, "box-b", at(n), at(n), `{"n":"`+uuid4()+`"}`)
				m.ParentTaskID, m.IsParent = parent, isParent
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}
			T, U, S, L := uuid4(), uuid4(), uuid4(), uuid4()
			c := put(T, "", 1, 0)        // the card
			r1 := put(T, "", 0, 1)       // replies
			r2 := put(T, "", 0, 2)       //
			x1 := put(r1.MsgID, T, 0, 3) // a thread opened on r1
			s1 := put(S, T, 1, 4)        // a sub-task of T
			d := put(U, "", 1, 5)        // another topic
			du := put(U, "", 0, 6)       //
			l1 := put(L, "", 1, 7)       // lobby cards
			l2 := put(L, "", 1, 8)       //
			y := put(l1.MsgID, L, 0, 9)  // l1's thread
			if err := s.AddReaction(ctx, tid, r1.MsgID, "HUM-1", "👍", now); err != nil {
				t.Fatal(err)
			}
			if _, err := s.ApplyEdit(ctx, tid, r2.MsgID, Edit{Body: "fixed", Msg: r2.Msg, Env: r2.Env, EditedBy: "GRK-03", EditedAt: at(20)}); err != nil {
				t.Fatal(err)
			}
			if _, err := s.SetKind(ctx, tid, c.MsgID, "blocker", "HUM-1", at(21)); err != nil {
				t.Fatal(err)
			}
			if err := s.Enqueue(ctx, tid, x1.MsgID, "box-b", now, at(3600), 100); err != nil {
				t.Fatal(err)
			}
			q := func() map[string]bool {
				t.Helper()
				rows, err := s.ViewTopics(ctx, tid, TopicQuery{Lobby: L, Limit: 50, Now: now})
				if err != nil {
					t.Fatal(err)
				}
				out := map[string]bool{}
				for _, r := range rows {
					out[r.TaskID] = true
				}
				return out
			}
			searched := func() map[string]bool {
				t.Helper()
				sqy := sq(t, "hi", now)
				sqy.Lobby, sqy.Limit = L, 100
				rows, err := s.(Searcher).SearchMessages(ctx, tid, sqy)
				if err != nil {
					t.Fatal(err)
				}
				out := map[string]bool{}
				for _, r := range rows {
					out[r.MsgID] = true
				}
				return out
			}

			// A card is the first row of its task; a reply is not.
			if st, err := s.CardState(ctx, tid, c.MsgID, now); err != nil || !st.FirstOfTask || st.IsParent != 1 {
				t.Fatalf("card state: %+v %v", st, err)
			}
			if st, _ := s.CardState(ctx, tid, r1.MsgID, now); st.FirstOfTask {
				t.Fatal("a reply read as first of its task")
			}
			if _, err := s.CardState(ctx, newTenant(t, s), c.MsgID, now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("another tenant's card: %v", err)
			}
			if got := q(); !got[T] || !got[U] || !got[L] || !got[l1.MsgID] {
				t.Fatalf("before archive, lists: %v", got)
			}

			// Archive T's card: T leaves the lists and search, its read stays.
			st, err := s.SetArchived(ctx, tid, c.MsgID, "HUM-1", at(30), true)
			if err != nil || !st.ArchivedAt.Equal(at(30)) || st.ArchivedBy != "HUM-1" {
				t.Fatalf("archive: %+v %v", st, err)
			}
			if st, _ := s.SetArchived(ctx, tid, c.MsgID, "HUM-2", at(40), true); !st.ArchivedAt.Equal(at(30)) || st.ArchivedBy != "HUM-1" {
				t.Fatalf("a second archive moved the first stamp: %+v", st)
			}
			if got := q(); got[T] || !got[U] || !got[L] {
				t.Fatalf("archived T still listed / others lost: %v", got)
			}
			if got := searched(); got[c.MsgID] || got[r1.MsgID] || got[x1.MsgID] || !got[d.MsgID] || !got[l2.MsgID] {
				t.Fatalf("search after archive: %v", got)
			}
			if rows, _ := s.ViewTopic(ctx, tid, TopicMsgQuery{TaskID: T, Limit: 10, Now: now}); len(rows) != 3 {
				t.Fatalf("an archived topic is still readable by task id: %d rows", len(rows))
			}

			// Archive lobby card l1: its row and thread go, the lobby stays.
			if _, err := s.SetArchived(ctx, tid, l1.MsgID, "HUM-1", at(31), true); err != nil {
				t.Fatal(err)
			}
			if got := q(); !got[L] || got[l1.MsgID] {
				t.Fatalf("lobby card archive: %v", got)
			}
			lobby, _ := s.ViewTopic(ctx, tid, TopicMsgQuery{TaskID: L, HideArchived: true, Limit: 10, Now: now})
			if len(lobby) != 1 || lobby[0].MsgID != l2.MsgID {
				t.Fatalf("lobby feed: %+v", lobby)
			}
			if b, ok := s.(TopicsMessager); ok {
				got, _, err := b.ViewTopicsMessages(ctx, tid, TopicsMsgQuery{TaskIDs: []string{L, U}, PerTopic: 5, HideArchivedIn: L, Now: now})
				if err != nil || len(got[L]) != 1 || got[L][0].MsgID != l2.MsgID || len(got[U]) != 2 {
					t.Fatalf("batch lobby read: %v %+v", err, got)
				}
			}
			if got := searched(); got[l1.MsgID] || got[y.MsgID] || !got[l2.MsgID] {
				t.Fatalf("search after lobby archive: %v", got)
			}

			// The Archive view: newest archived first.
			cards, err := s.ArchivedCards(ctx, tid, ArchivedQuery{Limit: 10, Now: now})
			if err != nil || len(cards) != 2 || cards[0].MsgID != l1.MsgID || cards[1].MsgID != c.MsgID || cards[1].TaskID != T {
				t.Fatalf("archived cards: %v %+v", err, cards)
			}
			if page, _ := s.ArchivedCards(ctx, tid, ArchivedQuery{Limit: 10, Now: now, BeforeAt: cards[0].ArchivedAt, BeforeID: cards[0].MsgID}); len(page) != 1 || page[0].MsgID != c.MsgID {
				t.Fatalf("archived page 2: %+v", page)
			}
			if n, err := s.TopicReplies(ctx, tid, []string{c.MsgID, l1.MsgID}, []string{T, ""}); err != nil || n[c.MsgID] != 4 || n[l1.MsgID] != 1 {
				t.Fatalf("reply counts: %v %v", n, err)
			}

			// Unarchive: T is back.
			if st, err := s.SetArchived(ctx, tid, c.MsgID, "HUM-1", at(50), false); err != nil || !st.ArchivedAt.IsZero() || st.ArchivedBy != "" {
				t.Fatalf("unarchive: %+v %v", st, err)
			}
			if got := q(); !got[T] {
				t.Fatalf("unarchived T not listed: %v", got)
			}

			// Delete T: the card and its four children, nothing else.
			set, err := s.DeleteTopic(ctx, tid, c.MsgID, T)
			if err != nil {
				t.Fatal(err)
			}
			want := []string{c.MsgID, r1.MsgID, r2.MsgID, x1.MsgID, s1.MsgID}
			got := append([]string{}, set.MsgIDs...)
			sort.Strings(got)
			sort.Strings(want)
			if len(got) != len(want) || set.MsgIDs[0] != c.MsgID || set.Replies() != 4 {
				t.Fatalf("deleted %v, want %v", set.MsgIDs, want)
			}
			for i := range want {
				if got[i] != want[i] {
					t.Fatalf("deleted %v, want %v", got, want)
				}
			}
			for _, id := range want {
				if ok, _ := s.HasMessage(ctx, tid, id); ok {
					t.Fatalf("%s survived the delete", id)
				}
			}
			for _, id := range []string{d.MsgID, du.MsgID, l1.MsgID, l2.MsgID, y.MsgID} {
				if ok, _ := s.HasMessage(ctx, tid, id); !ok {
					t.Fatalf("%s was not in the topic and is gone", id)
				}
			}
			if rs, _ := s.ReactionsFor(ctx, tid, []string{r1.MsgID}); len(rs[r1.MsgID]) != 0 {
				t.Fatalf("reactions survived: %v", rs)
			}
			if revs, _ := s.MessageRevisions(ctx, tid, r2.MsgID); len(revs) != 0 {
				t.Fatalf("revisions survived: %v", revs)
			}
			if kc, _ := s.KindChanges(ctx, tid, c.MsgID); len(kc) != 0 {
				t.Fatalf("kind changes survived: %v", kc)
			}
			if _, err := s.DeliveryState(ctx, tid, x1.MsgID, "box-b"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("delivery survived: %v", err)
			}
			if _, err := s.DeleteTopic(ctx, tid, c.MsgID, T); !errors.Is(err, ErrNotFound) {
				t.Fatalf("second delete: %v", err)
			}

			// Delete lobby card l1: it and its thread, never the lobby.
			set, err = s.DeleteTopic(ctx, tid, l1.MsgID, "")
			if err != nil || len(set.MsgIDs) != 2 {
				t.Fatalf("lobby card delete: %+v %v", set, err)
			}
			if ok, _ := s.HasMessage(ctx, tid, l2.MsgID); !ok {
				t.Fatal("deleting one lobby card took another")
			}
		})
	}
}

// A topic whose OLDEST row is not its card - a channel reply, a moved-in
// message or a desk DM (is_parent=0) received before the opening card - was
// stuck: the card failed the "first row of the task" test, so it could be
// neither archived nor deleted (prd t1 topic e802196b, 2026-09-29). The
// opening card is the earliest is_parent=1 row (TopicChannel / TaskCard),
// not the earliest row of any level. This is the control for that fix:
// before it, CardState(card).FirstOfTask is false and the archive/delete
// below refuse; after it, the card opens its topic and both succeed.
func TestTopicArchiveOldestRowIsReply(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			at := func(n int) time.Time { return now.Add(time.Duration(n) * time.Second) }
			put := func(task, parent string, isParent, n int) Message {
				t.Helper()
				m := msgFor(tid, task, "box-b", at(n), at(n), `{"n":"`+uuid4()+`"}`)
				m.ParentTaskID, m.IsParent = parent, isParent
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				return m
			}
			T := uuid4()
			r0 := put(T, "", 0, 0)    // the oldest row is a reply / moved-in message
			card := put(T, "", 1, 1)  // the opening card, received AFTER r0
			r1 := put(T, "", 0, 2)    // a later reply
			card2 := put(T, "", 1, 3) // a second card is never the opener

			// The card opens its topic even though r0 came first; a later
			// is_parent=1 row does not, and neither reply is a card.
			if st, err := s.CardState(ctx, tid, card.MsgID, now); err != nil || !st.FirstOfTask || st.IsParent != 1 {
				t.Fatalf("card state: %+v %v", st, err)
			}
			if st, _ := s.CardState(ctx, tid, card2.MsgID, now); st.FirstOfTask {
				t.Fatal("a later card read as the topic's opener")
			}
			if st, _ := s.CardState(ctx, tid, r1.MsgID, now); st.IsParent == 1 {
				t.Fatal("a reply read as a card")
			}

			// Archive the card: the topic leaves the list, its rows stay.
			if st, err := s.SetArchived(ctx, tid, card.MsgID, "HUM-1", at(30), true); err != nil || st.ArchivedAt.IsZero() {
				t.Fatalf("archive: %+v %v", st, err)
			}
			rows, err := s.ViewTopics(ctx, tid, TopicQuery{Limit: 50, Now: now})
			if err != nil {
				t.Fatal(err)
			}
			for _, r := range rows {
				if r.TaskID == T {
					t.Fatal("archived topic still listed")
				}
			}
			if _, err := s.SetArchived(ctx, tid, card.MsgID, "HUM-1", at(31), false); err != nil {
				t.Fatal(err)
			}

			// Delete the card: every row of the task goes, the card first.
			set, err := s.DeleteTopic(ctx, tid, card.MsgID, T)
			if err != nil {
				t.Fatal(err)
			}
			if len(set.MsgIDs) != 4 || set.MsgIDs[0] != card.MsgID {
				t.Fatalf("deleted %v, want 4 rows, card first", set.MsgIDs)
			}
			for _, id := range []string{r0.MsgID, card.MsgID, r1.MsgID, card2.MsgID} {
				if ok, _ := s.HasMessage(ctx, tid, id); ok {
					t.Fatalf("%s survived the delete", id)
				}
			}
		})
	}
}

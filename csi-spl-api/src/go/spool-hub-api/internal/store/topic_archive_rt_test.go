package store

// perf edition 20261004 E09 (G2's practice, kill an N+1 loop): the Archive
// view's reply counts (TopicReplies) walked every card's topic one level per
// round trip, inside BEGIN..COMMIT. The topic preview (TopicOf, a GET) took
// the card row FOR UPDATE, so a write on that card waited for a read. Both
// now walk every card against one shared row cache, one round trip per level
// of the deepest topic, with no transaction and no lock. The parity test
// pins the answers on both drivers; the others need SPOOL_TEST_PG_DSN.
//
//	SPOOL_TEST_PG_DSN=... go test ./internal/store -run 'TestTopicWalk|TestTopicArchiveRoundTrips' -v

import (
	"context"
	"errors"
	"net/url"
	"os"
	"sort"
	"testing"
	"time"
)

// topicFixture stores one card per shape the walk must follow and answers
// the cards, their own tasks and the reply count each must get.
func topicFixture(t *testing.T, s Store, tid string, now time.Time) (cards, own []string, want map[string]int) {
	t.Helper()
	ctx := context.Background()
	n := 0
	put := func(task, parent string, isParent int) Message {
		t.Helper()
		n++
		at := now.Add(time.Duration(n) * time.Second)
		m := msgFor(tid, task, "box-b", at, at, `{"n":"`+uuid4()+`"}`)
		m.ParentTaskID, m.IsParent = parent, isParent
		if _, err := s.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		return m
	}
	want = map[string]int{}
	add := func(card Message, ownTask string, replies int) {
		cards, own = append(cards, card.MsgID), append(own, ownTask)
		want[card.MsgID] = replies
	}
	T := uuid4() // replies, a thread on a reply, a thread in that thread, a sub-task
	c := put(T, "", 1)
	r1 := put(T, "", 0)
	put(T, "", 0)
	x1 := put(r1.MsgID, T, 0)
	put(x1.MsgID, r1.MsgID, 0)
	S := uuid4()
	put(S, T, 1)
	put(S, "", 0)
	add(c, T, 6)
	U := uuid4() // a lone card
	add(put(U, "", 1), U, 0)
	L := uuid4() // two lobby cards: each is its own thread's root, never the lobby
	l1 := put(L, "", 1)
	l2 := put(L, "", 1)
	put(l1.MsgID, L, 0)
	put(l1.MsgID, L, 0)
	add(l1, "", 2)
	add(l2, "", 0)
	return cards, own, want
}

// Both drivers answer the same rows and counts for every shape, a missing
// card is ErrNotFound and a chain past maxTopicWalk is ErrConflict.
func TestTopicWalkParity(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			cards, own, want := topicFixture(t, s, tid, now)
			replies, err := s.TopicReplies(ctx, tid, cards, own)
			if err != nil {
				t.Fatal(err)
			}
			for i, id := range cards {
				if replies[id] != want[id] {
					t.Errorf("TopicReplies card %d: %d replies, want %d", i, replies[id], want[id])
				}
				set, err := s.TopicOf(ctx, tid, id, own[i])
				if err != nil {
					t.Fatal(err)
				}
				if set.MsgIDs[0] != id || set.Replies() != want[id] {
					t.Errorf("TopicOf card %d: first %s, %d replies, want %s / %d", i, set.MsgIDs[0], set.Replies(), id, want[id])
				}
				seen := map[string]bool{}
				for _, m := range set.MsgIDs {
					if seen[m] {
						t.Errorf("TopicOf card %d: %s twice", i, m)
					}
					seen[m] = true
				}
			}
			if _, err := s.TopicOf(ctx, tid, uuid4(), ""); !errors.Is(err, ErrNotFound) {
				t.Fatalf("TopicOf of a missing card: %v, want ErrNotFound", err)
			}
			deep := uuid4() // a chain nested past maxTopicWalk is a bug, not a topic
			top := msgFor(tid, deep, "box-b", now, now, `{"n":"`+uuid4()+`"}`)
			top.IsParent = 1
			if _, err := s.InsertMessage(ctx, top); err != nil {
				t.Fatal(err)
			}
			task := top.MsgID // each row a thread on the one before: one level each
			for i := 0; i <= maxTopicWalk; i++ {
				m := msgFor(tid, task, "box-b", now, now, `{"n":"`+uuid4()+`"}`)
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
				task = m.MsgID
			}
			if _, err := s.TopicOf(ctx, tid, top.MsgID, deep); !errors.Is(err, ErrConflict) {
				t.Fatalf("TopicOf past maxTopicWalk: %v, want ErrConflict", err)
			}
			if _, ok := s.(*Postgres); ok { // the memory driver skips that card instead (unchanged)
				if _, err := s.TopicReplies(ctx, tid, append(cards, top.MsgID), append(own, deep)); !errors.Is(err, ErrConflict) {
					t.Fatalf("TopicReplies past maxTopicWalk: %v, want ErrConflict", err)
				}
			}
		})
	}
}

// proxiedStore opens a Postgres store behind the counting proxy of
// write_batch_rt_test.go.
func proxiedStore(t *testing.T) (pg *Postgres, proxy *rtProxy) {
	t.Helper()
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	u, err := url.Parse(dsn)
	if err != nil {
		t.Fatal(err)
	}
	if u.Host == "" {
		t.Skip("SPOOL_TEST_PG_DSN is a unix socket; the counting proxy needs TCP")
	}
	ctx := context.Background()
	direct, err := OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(direct.Close)
	if _, err := Migrate(ctx, direct.Pool(), sqlDir(t)); err != nil {
		t.Fatal(err)
	}
	proxy = newRTProxy(t, u.Host)
	u.Host = proxy.ln.Addr().String()
	if pg, err = OpenPostgres(ctx, u.String()); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(pg.Close)
	return pg, proxy
}

// rtCounts runs fn n times after one warm-up and answers the sorted
// round-trip counts.
func rtCounts(t *testing.T, p *rtProxy, n int, fn func() error) []int64 {
	t.Helper()
	if err := fn(); err != nil {
		t.Fatal(err)
	}
	out := make([]int64, 0, n)
	for i := 0; i < n; i++ {
		before := p.packets.Load()
		if err := fn(); err != nil {
			t.Fatal(err)
		}
		out = append(out, p.packets.Load()-before)
	}
	sort.Slice(out, func(a, b int) bool { return out[a] < out[b] })
	return out
}

// TopicReplies costs one round trip per level of the deepest topic at any
// card count.
func TestTopicArchiveRoundTrips(t *testing.T) {
	pg, proxy := proxiedStore(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	tid := newTenant(t, pg)
	var cards, own []string
	for len(cards) < 50 {
		T := uuid4() // a card, a reply and a thread on the reply: two levels
		c := msgFor(tid, T, "box-b", now, now, `{"n":"`+uuid4()+`"}`)
		c.IsParent = 1
		r := msgFor(tid, T, "box-b", now, now, `{"n":"`+uuid4()+`"}`)
		x := msgFor(tid, r.MsgID, "box-b", now, now, `{"n":"`+uuid4()+`"}`)
		x.ParentTaskID = T
		for _, m := range []Message{c, r, x} {
			if _, err := pg.InsertMessage(ctx, m); err != nil {
				t.Fatal(err)
			}
		}
		cards, own = append(cards, c.MsgID), append(own, T)
	}
	const n = 5
	for _, k := range []int{0, 5, 15, 50} {
		rt := rtCounts(t, proxy, n, func() error {
			got, err := pg.TopicReplies(ctx, tid, cards[:k], own[:k])
			for _, id := range cards[:k] {
				if err == nil && got[id] != 2 {
					return errors.New("wrong reply count")
				}
			}
			return err
		})
		t.Logf("TopicReplies k=%-2d RT n=%d min/median/max %d/%d/%d", k, n, rt[0], rt[n/2], rt[n-1])
		if rt[n/2] > 2 {
			t.Errorf("TopicReplies k=%d: median %d round trips, budget 2 (one per topic level)", k, rt[n/2])
		}
	}
}

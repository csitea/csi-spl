// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 196 row T1 (rdb 0328, SPL-6562): topic tags. The normaliser is pure;
// the add / remove / cap / delete / merge cases run on Memory always and on
// Postgres with a DSN (hub-pg.tst.sh, PRE_PUSH_TIER=full); the concurrency
// and channel move cases are Postgres only. RLS, the change stamp and the
// cross-tenant census are rls_test.go, change_stamp_test.go and
// crosstenant_test.go.

// TestNormalizeTopicTag: NFC lower case, '#' and spaces folded, every script
// of the 19 locales kept, and the separators of a multi-tag URL refused.
func TestNormalizeTopicTag(t *testing.T) {
	ok := map[string]string{
		"billing":               "billing",
		"  #Billing ":           "billing",
		"##BILLING":             "billing",
		"Release Notes":         "release-notes",
		"release - -notes":      "release-notes",
		"-a-":                   "a",
		"v1.2_rc":               "v1.2_rc",
		"éclair":               "éclair", // decomposed e + U+0301 == composed é
		"ÉCLAIR":                "éclair",
		"\u0130stanbul":         "istanbul",       // Go lowers Turkish \u0130 to plain i (unicode.ToLower, no special casing)
		"i\u0307stanbul":        "i\u0307stanbul", // i + U+0307, a \p{Mn} after a letter, is kept
		"ISTANBUL":              "istanbul",
		"ıstanbul":              "ıstanbul", // dotless ı stays
		"Привет Мир":            "привет-мир",
		"שָׁלוֹם":               "שָׁלוֹם", // Hebrew with niqqud
		"日本語":                   "日本語",
		strings.Repeat("a", 40): strings.Repeat("a", 40),
	}
	for raw, want := range ok {
		if got, err := NormalizeTopicTag(raw); err != nil || got != want {
			t.Errorf("NormalizeTopicTag(%q) = %q, %v; want %q", raw, got, err, want)
		}
	}
	for _, raw := range []string{"", " ", "#", "-", "--", ".", "..", "_", "a,b", ",", "a/b", "a\\b", "\"a\"", "'a'",
		"<b>", "a\tb\x00", "a​b", "́a", "1́", "a b,c", strings.Repeat("a", 41), strings.Repeat("ж", 41),
		strings.Repeat("\U00020000", 33), // 33 runes, 132 bytes: over the 128-byte cap
		"a:b", "a#b", "a?b", "a%b"} {
		if got, err := NormalizeTopicTag(raw); !errors.Is(err, ErrBadTopicTag) {
			t.Errorf("NormalizeTopicTag(%q) = %q, %v; want ErrBadTopicTag", raw, got, err)
		}
	}
}

// topicTagExists says whether the workspace's tag list holds slug.
func topicTagExists(t *testing.T, s Store, tenant, slug string) bool {
	t.Helper()
	switch st := s.(type) {
	case *Memory:
		st.mu.Lock()
		defer st.mu.Unlock()
		_, ok := st.topicTagsLocked().tags[[2]string{tenant, slug}]
		return ok
	case *Postgres:
		return mvCount(t, st, `SELECT count(*) FROM topic_tags WHERE tenant_id = $1 AND slug = $2`, tenant, slug) == 1
	}
	t.Fatalf("no topic tag store %T", s)
	return false
}

// topicTagSlugsOf is the topic's slugs through the store API.
func topicTagSlugsOf(t *testing.T, s Store, tenant, task string) []string {
	t.Helper()
	got, err := s.(TopicTagStore).TopicTagLinks(context.Background(), tenant, []string{task})
	if err != nil {
		t.Fatal(err)
	}
	out := []string{}
	for _, l := range got[strings.ToLower(task)] {
		out = append(out, l.Slug)
	}
	return out
}

// TestTopicTagAddRemove: an add normalises and links, a second add of the
// same slug in any spelling is a no-op, a remove unlinks and prunes the
// unused tag, a tag another topic uses stays, and another workspace reads
// nothing for the same task id.
func TestTopicTagAddRemove(t *testing.T) {
	ctx := context.Background()
	at := time.Now().UTC().Truncate(time.Microsecond)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ts := s.(TopicTagStore)
			tid, other := newTenant(t, s), newTenant(t, s)
			task, task2 := uuid4(), uuid4()
			ch, err := ts.AddTopicTag(ctx, tid, strings.ToUpper(task), "  #Billing ", "HUM-1", at)
			if err != nil || !ch.Changed || ch.Slug != "billing" || ch.TaskID != task || !reflect.DeepEqual(ch.Tags, []string{"billing"}) {
				t.Fatalf("add: %+v %v", ch, err)
			}
			if ch, err = ts.AddTopicTag(ctx, tid, task, "BILLING", "HUM-2", at); err != nil || ch.Changed {
				t.Fatalf("second add: %+v %v, want a no-op", ch, err)
			}
			if ch, err = ts.AddTopicTag(ctx, tid, task, "Release Notes", "HUM-2", at.Add(time.Second)); err != nil ||
				!reflect.DeepEqual(ch.Tags, []string{"billing", "release-notes"}) {
				t.Fatalf("add a second tag: %+v %v", ch, err)
			}
			if _, err = ts.AddTopicTag(ctx, tid, task2, "billing", "HUM-3", at); err != nil {
				t.Fatal(err)
			}
			links, err := ts.TopicTagLinks(ctx, tid, []string{task, "not-a-uuid"})
			want := []TopicTagLink{{"billing", "HUM-1", at}, {"release-notes", "HUM-2", at.Add(time.Second)}}
			if err != nil || len(links) != 1 || !reflect.DeepEqual(links[task], want) {
				t.Fatalf("links: %+v %v, want %+v", links, err, want)
			}
			if got := topicTagSlugsOf(t, s, other, task); len(got) != 0 {
				t.Fatalf("another workspace reads %v", got)
			}
			if ch, err = ts.RemoveTopicTag(ctx, tid, task, "#RELEASE notes", "HUM-1", at); err != nil || !ch.Changed ||
				!reflect.DeepEqual(ch.Tags, []string{"billing"}) {
				t.Fatalf("remove: %+v %v", ch, err)
			}
			if topicTagExists(t, s, tid, "release-notes") {
				t.Error("an unused tag was not pruned")
			}
			if ch, err = ts.RemoveTopicTag(ctx, tid, task, "billing", "HUM-1", at); err != nil || !ch.Changed || len(ch.Tags) != 0 {
				t.Fatalf("remove billing: %+v %v", ch, err)
			}
			if !topicTagExists(t, s, tid, "billing") {
				t.Error("a tag task2 still uses was pruned")
			}
			if ch, err = ts.RemoveTopicTag(ctx, tid, task, "billing", "HUM-1", at); err != nil || ch.Changed {
				t.Fatalf("remove again: %+v %v, want a no-op", ch, err)
			}
			checkTopicTagRefusals(t, ts, tid, task, at)
		})
	}
}

func checkTopicTagRefusals(t *testing.T, ts TopicTagStore, tid, task string, at time.Time) {
	t.Helper()
	ctx := context.Background()
	if _, err := ts.AddTopicTag(ctx, tid, task, "a,b", "HUM-1", at); !errors.Is(err, ErrBadTopicTag) {
		t.Errorf("comma: %v, want ErrBadTopicTag", err)
	}
	if _, err := ts.RemoveTopicTag(ctx, tid, task, ",", "HUM-1", at); !errors.Is(err, ErrBadTopicTag) {
		t.Errorf("remove a comma: %v, want ErrBadTopicTag", err)
	}
	if _, err := ts.AddTopicTag(ctx, tid, "not-a-uuid", "ok", "HUM-1", at); !errors.Is(err, ErrBadTopicTask) {
		t.Errorf("no uuid: %v, want ErrBadTopicTask", err)
	}
	if _, err := ts.AddTopicTag(ctx, uid("t-"), task, "ok", "HUM-1", at); !errors.Is(err, ErrNotFound) {
		t.Errorf("no workspace: %v, want ErrNotFound", err)
	}
	if _, err := ts.RemoveTopicTag(ctx, uid("t-"), task, "ok", "HUM-1", at); !errors.Is(err, ErrNotFound) {
		t.Errorf("remove, no workspace: %v, want ErrNotFound", err)
	}
	if _, err := ts.AddTopicTag(ctx, "", task, "ok", "HUM-1", at); !errors.Is(err, ErrNoTenant) {
		t.Errorf("empty tenant: %v, want ErrNoTenant", err)
	}
}

// TestTopicTagCap: the 11th tag is refused and leaves no workspace tag
// behind; re-adding one of the 10 is still a no-op.
func TestTopicTagCap(t *testing.T) {
	ctx := context.Background()
	at := time.Now().UTC()
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ts, tid, task := s.(TopicTagStore), newTenant(t, s), uuid4()
			for i := range TopicTagsMax {
				if _, err := ts.AddTopicTag(ctx, tid, task, fmt.Sprintf("tag-%02d", i), "HUM-1", at); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := ts.AddTopicTag(ctx, tid, task, "eleventh", "HUM-1", at); !errors.Is(err, ErrTooManyTopicTags) {
				t.Fatalf("11th: %v, want ErrTooManyTopicTags", err)
			}
			if topicTagExists(t, s, tid, "eleventh") {
				t.Error("the refused 11th tag stayed in the workspace's list")
			}
			if ch, err := ts.AddTopicTag(ctx, tid, task, "TAG-03", "HUM-1", at); err != nil || ch.Changed || len(ch.Tags) != TopicTagsMax {
				t.Fatalf("re-add at the cap: %+v %v", ch, err)
			}
		})
	}
}

// TestTopicTagCapConcurrent: 20 parallel adds of distinct tags on one topic
// end with exactly 10 links, 10 refusals and no stray workspace tag (the
// topic_tag_stamps row lock, spec 196 2.3 rule 1).
func TestTopicTagCapConcurrent(t *testing.T) {
	pg := rlsStore(t)
	ctx, at := context.Background(), time.Now().UTC()
	tid, task := newTenant(t, pg), uuid4()
	var wg sync.WaitGroup
	var mu sync.Mutex
	errs := map[string]int{}
	for i := range 20 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			_, err := pg.AddTopicTag(ctx, tid, task, fmt.Sprintf("c-%02d", i), "HUM-1", at)
			mu.Lock()
			defer mu.Unlock()
			errs[fmt.Sprint(err)]++
		}()
	}
	wg.Wait()
	if errs["<nil>"] != TopicTagsMax || errs[ErrTooManyTopicTags.Error()] != 20-TopicTagsMax {
		t.Fatalf("outcomes %v, want %d ok and %d refused", errs, TopicTagsMax, 20-TopicTagsMax)
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM topic_tag_links WHERE tenant_id = $1 AND task_id = $2`, tid, task); n != TopicTagsMax {
		t.Errorf("%d links, want %d", n, TopicTagsMax)
	}
	if n := mvCount(t, pg, `SELECT count(*) FROM topic_tags WHERE tenant_id = $1`, tid); n != TopicTagsMax {
		t.Errorf("%d workspace tags, want %d (a refused add left one)", n, TopicTagsMax)
	}
}

// TestTopicTagPruneWaitsForAdd: a remove that would prune a tag while
// another topic's add holds it FOR KEY SHARE waits, and then keeps the tag
// that add linked (spec 196 2.3 rule 2).
func TestTopicTagPruneWaitsForAdd(t *testing.T) {
	pg := rlsStore(t)
	ctx, at := context.Background(), time.Now().UTC()
	tid, x, y := newTenant(t, pg), uuid4(), uuid4()
	if _, err := pg.AddTopicTag(ctx, tid, x, "shared", "HUM-1", at); err != nil {
		t.Fatal(err)
	}
	held, release, addDone := make(chan struct{}), make(chan struct{}), make(chan error, 1)
	go func() {
		addDone <- pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
			tagID, err := topicTagHoldTx(ctx, tx, tid, "shared", "HUM-2", at)
			if err != nil {
				return err
			}
			close(held)
			<-release
			_, err = topicTagLinkTx(ctx, tx, tid, y, tagID, "HUM-2", at)
			return err
		})
	}()
	<-held
	removeDone := make(chan error, 1)
	go func() {
		_, err := pg.RemoveTopicTag(ctx, tid, x, "shared", "HUM-1", at)
		removeDone <- err
	}()
	waitTopicTagLockWait(t, pg, "%topic_tags%FOR UPDATE%")
	close(release)
	if err := <-addDone; err != nil {
		t.Fatal(err)
	}
	if err := <-removeDone; err != nil {
		t.Fatal(err)
	}
	if !topicTagExists(t, pg, tid, "shared") || !reflect.DeepEqual(topicTagSlugsOf(t, pg, tid, y), []string{"shared"}) {
		t.Fatalf("the prune removed a tag a concurrent add linked: y has %v", topicTagSlugsOf(t, pg, tid, y))
	}
	if got := topicTagSlugsOf(t, pg, tid, x); len(got) != 0 {
		t.Fatalf("x still has %v", got)
	}
}

// waitTopicTagLockWait waits for the event the test then relies on: a
// session of this database whose statement matches like waiting on a row
// lock (the prune's FOR UPDATE, the merge's stamp upsert).
func waitTopicTagLockWait(t *testing.T, pg *Postgres, like string) {
	t.Helper()
	deadline := time.Now().Add(30 * time.Second)
	for time.Now().Before(deadline) {
		var n int
		if err := pg.pool.QueryRow(context.Background(), `SELECT count(*) FROM pg_stat_activity
			WHERE datname = current_database() AND wait_event_type = 'Lock' AND query LIKE $1`, like).Scan(&n); err != nil {
			t.Fatal(err)
		}
		if n > 0 {
			return
		}
		time.Sleep(10 * time.Millisecond) // a poll step, the budget above is the cap
	}
	t.Fatalf("no statement like %q waited on a lock", like)
}

// TestTopicTagDeleteTopic: a deleted topic's links and stamp go, its tag no
// other topic uses is pruned, a shared one stays.
func TestTopicTagDeleteTopic(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ts, tid := s.(TopicTagStore), newTenant(t, s)
			task, keep := uuid4(), uuid4()
			card := msgFor(tid, task, "box-b", now, now, `{"n":"`+uuid4()+`"}`)
			card.Channel = "devel"
			if _, err := s.InsertMessage(ctx, card); err != nil {
				t.Fatal(err)
			}
			for _, x := range []struct{ task, slug string }{{task, "only-here"}, {task, "shared"}, {keep, "shared"}} {
				if _, err := ts.AddTopicTag(ctx, tid, x.task, x.slug, "HUM-1", now); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := s.DeleteTopic(ctx, tid, card.MsgID, task, "HUM-1", now); err != nil {
				t.Fatal(err)
			}
			if got := topicTagSlugsOf(t, s, tid, task); len(got) != 0 {
				t.Errorf("the deleted topic kept %v", got)
			}
			if topicTagExists(t, s, tid, "only-here") || !topicTagExists(t, s, tid, "shared") {
				t.Errorf("prune: only-here %v (want gone), shared %v (want kept)",
					topicTagExists(t, s, tid, "only-here"), topicTagExists(t, s, tid, "shared"))
			}
			if pg, ok := s.(*Postgres); ok {
				if n := mvCount(t, pg, `SELECT count(*) FROM topic_tag_stamps WHERE tenant_id = $1 AND task_id = $2`, tid, task); n != 0 {
					t.Errorf("the deleted topic's stamp stayed (%d)", n)
				}
			}
		})
	}
}

// TestTopicTagMergeCap: merging A (6 tags) into B (8 tags, 2 shared) gives
// B its 8 and the 2 earliest-added of A's other 4, the tie on added_at at the
// cap broken by slug; the other 2 are dropped and pruned, A has none.
func TestTopicTagMergeCap(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	at := func(n int) time.Time { return now.Add(time.Duration(n) * time.Second) }
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ts, tid := s.(TopicTagStore), newTenant(t, s)
			A, B := uuid4(), uuid4()
			cardA := putTagCard(t, s, tid, A, now)
			putTagCard(t, s, tid, B, now.Add(time.Second))
			add := func(task, slug string, n int) {
				t.Helper()
				if _, err := ts.AddTopicTag(ctx, tid, task, slug, "HUM-1", at(n)); err != nil {
					t.Fatal(err)
				}
			}
			for i, slug := range []string{"b1", "b2", "b3", "b4", "b5", "b6", "s1", "s2"} {
				add(B, slug, i)
			}
			add(A, "s1", 0)
			add(A, "s2", 0)
			add(A, "zz-late", 9) // dropped: the latest
			add(A, "a-tie-y", 5) // dropped: tie on 5 at the cap, y after x
			add(A, "a-tie-x", 5) // kept: the 10th
			add(A, "m-early", 1) // kept: the earliest
			if _, err := s.MergeTopic(ctx, tid, MergeTopicReq{SrcMsgID: cardA, SrcTask: A, TargetTask: B, ToChannel: "ops", By: "HUM-1", At: at(20)}); err != nil {
				t.Fatal(err)
			}
			want := []string{"a-tie-x", "b1", "b2", "b3", "b4", "b5", "b6", "m-early", "s1", "s2"}
			if got := topicTagSlugsOf(t, s, tid, B); !reflect.DeepEqual(got, want) {
				t.Errorf("B after the merge: %v, want %v", got, want)
			}
			if got := topicTagSlugsOf(t, s, tid, A); len(got) != 0 {
				t.Errorf("A after the merge: %v, want none", got)
			}
			for _, slug := range []string{"zz-late", "a-tie-y"} {
				if topicTagExists(t, s, tid, slug) {
					t.Errorf("the dropped tag %s was not pruned", slug)
				}
			}
		})
	}
}

// TestTopicTagMergeWaitsForAdd: a merge of A queues behind an add on A that
// holds A's stamp row (spec 196 2.3 order: the stamp first, then the tag), so
// the add may still hold A's tags without a deadlock, and the tag it linked
// is merged into B, not lost.
func TestTopicTagMergeWaitsForAdd(t *testing.T) {
	pg := rlsStore(t)
	ctx, at := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	tid, A, B := newTenant(t, pg), uuid4(), uuid4()
	cardA := putTagCard(t, pg, tid, A, at)
	putTagCard(t, pg, tid, B, at.Add(time.Second))
	if _, err := pg.AddTopicTag(ctx, tid, A, "a1", "HUM-1", at); err != nil {
		t.Fatal(err)
	}
	held, release, addDone := make(chan struct{}), make(chan struct{}), make(chan error, 1)
	go func() {
		addDone <- pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, topicTagLock, tid, A, at); err != nil {
				return err
			}
			close(held)
			<-release
			for _, slug := range []string{"a1", "a-late"} {
				tagID, err := topicTagHoldTx(ctx, tx, tid, slug, "HUM-2", at)
				if err != nil {
					return err
				}
				if _, err = topicTagLinkTx(ctx, tx, tid, A, tagID, "HUM-2", at); err != nil {
					return err
				}
			}
			return nil
		})
	}()
	<-held
	mergeDone := make(chan error, 1)
	go func() {
		_, err := pg.MergeTopic(ctx, tid, MergeTopicReq{SrcMsgID: cardA, SrcTask: A, TargetTask: B, ToChannel: "ops", By: "HUM-1", At: at.Add(2 * time.Second)})
		mergeDone <- err
	}()
	waitTopicTagLockWait(t, pg, "%topic_tag_stamps%")
	close(release)
	if err := <-addDone; err != nil {
		t.Fatalf("the add on A: %v", err)
	}
	if err := <-mergeDone; err != nil {
		t.Fatalf("the merge: %v", err)
	}
	if got := topicTagSlugsOf(t, pg, tid, B); !reflect.DeepEqual(got, []string{"a-late", "a1"}) {
		t.Errorf("B after the merge: %v, want [a-late a1]", got)
	}
	if got := topicTagSlugsOf(t, pg, tid, A); len(got) != 0 {
		t.Errorf("A after the merge: %v, want none", got)
	}
}

func putTagCard(t *testing.T, s Store, tid, task string, at time.Time) string {
	t.Helper()
	m := msgFor(tid, task, "box-b", at, at, `{"n":"`+uuid4()+`"}`)
	m.Channel = "devel"
	if _, err := s.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
	return m.MsgID
}

// TestTopicTagChannelMoveRemap: a moved topic's tags arrive in <DST> by
// slug: "shared", which <DST> already has under its own tag_id, links to
// that tag_id; "fresh" is made in <DST>. <SRC> loses the links and prunes
// "fresh"; "shared" stays there for the staying topic.
// RED CONTROL: class topic_tag_links Moved (Set task_id = ANY(@tasks)) and the
// move inserts the <SRC> tag_id under <DST>: the FK refuses it.
func TestTopicTagChannelMoveRemap(t *testing.T) {
	f := seedMove(t)
	ctx, at := context.Background(), time.Now().UTC()
	dstTask := uuid4()
	for _, x := range []struct{ tenant, task, slug string }{
		{f.src, f.tA, "shared"}, {f.src, f.tA, "fresh"}, {f.src, f.tB, "shared"}, {f.dst, dstTask, "shared"},
	} {
		if _, err := f.pg.AddTopicTag(ctx, x.tenant, x.task, x.slug, f.both, at); err != nil {
			t.Fatal(err)
		}
	}
	dstShared := topicTagID(t, f.pg, f.dst, "shared")
	if dstShared == topicTagID(t, f.pg, f.src, "shared") {
		t.Fatal("control: the two workspaces' shared tags must differ")
	}
	res := f.apply(t, f.req())
	if got := topicTagSlugsOf(t, f.pg, f.dst, f.tA); !reflect.DeepEqual(got, []string{"fresh", "shared"}) {
		t.Fatalf("topic A in <DST>: %v", got)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM topic_tag_links WHERE tenant_id = $1 AND task_id = $2 AND tag_id = $3`,
		f.dst, f.tA, dstShared); n != 1 {
		t.Errorf("topic A's shared link names <DST>'s tag_id %d time(s), want 1", n)
	}
	if got := topicTagSlugsOf(t, f.pg, f.src, f.tA); len(got) != 0 {
		t.Errorf("<SRC> kept topic A's links %v", got)
	}
	if topicTagExists(t, f.pg, f.src, "fresh") || !topicTagExists(t, f.pg, f.src, "shared") {
		t.Error("<SRC> prune: fresh must go, shared (topic B) stay")
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM topic_tag_stamps WHERE task_id = $1 AND tenant_id = ANY($2)`,
		f.tA, []string{f.dst}); n != 1 {
		t.Errorf("topic A's stamp in <DST>: %d, want 1", n)
	}
	if res.Copied["topic_tag_links"] != 2 || res.Deleted["topic_tag_links"] != 2 {
		t.Errorf("result counts: copied %d, deleted %d; want 2, 2", res.Copied["topic_tag_links"], res.Deleted["topic_tag_links"])
	}
}

func topicTagID(t *testing.T, pg *Postgres, tenant, slug string) string {
	t.Helper()
	var id string
	err := pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT tag_id::text FROM topic_tags WHERE tenant_id = $1 AND slug = $2`, tenant, slug).Scan(&id)
	})
	if err != nil {
		t.Fatal(err)
	}
	return id
}

// TestTopicTagChannelCopyRemap: a copied topic gets the tags under its new
// task id and <DST>'s tag_ids; <SRC> keeps its own links and tags.
func TestTopicTagChannelCopyRemap(t *testing.T) {
	f := seedCopy(t)
	ctx, at := context.Background(), time.Now().UTC()
	for _, x := range []struct{ tenant, task, slug string }{{f.src, f.tA, "shared"}, {f.src, f.tA, "fresh"}, {f.dst, uuid4(), "shared"}} {
		if _, err := f.pg.AddTopicTag(ctx, x.tenant, x.task, x.slug, f.both, at); err != nil {
			t.Fatal(err)
		}
	}
	res := f.apply(t, f.req())
	newA := res.IDs[f.tA]
	if newA == "" || newA == f.tA {
		t.Fatalf("topic A's new id %q", newA)
	}
	if got := topicTagSlugsOf(t, f.pg, f.dst, newA); !reflect.DeepEqual(got, []string{"fresh", "shared"}) {
		t.Fatalf("the copy of topic A in <DST>: %v", got)
	}
	if n := mvCount(t, f.pg, `SELECT count(*) FROM topic_tag_links l JOIN topic_tags t ON t.tenant_id = l.tenant_id AND t.tag_id = l.tag_id
		WHERE l.tenant_id = $1 AND l.task_id = $2 AND t.slug = 'shared' AND t.tag_id = $3`, f.dst, newA, topicTagID(t, f.pg, f.dst, "shared")); n != 1 {
		t.Errorf("the copy's shared link names <DST>'s tag %d time(s), want 1", n)
	}
	if got := topicTagSlugsOf(t, f.pg, f.src, f.tA); !reflect.DeepEqual(got, []string{"fresh", "shared"}) {
		t.Errorf("<SRC> topic A after the copy: %v", got)
	}
}

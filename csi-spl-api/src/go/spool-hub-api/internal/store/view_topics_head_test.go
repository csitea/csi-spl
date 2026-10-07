package store

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strconv"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 099 T005: the head read. The case table (TestTopicHeadCases) and the
// random sequences (TestTopicHeadRandomSequences) compare it with the walk
// through topicHeadRead on every shape and page; this file adds the backfill
// gate, the uuid order, a seeded oracle run and the batch header A/B.
// SPOOL_TEST_TOPIC_HEADS=on runs every other view test of the package on the
// head read too (TopicHeadsTestAll).
func init() {
	TopicHeadsTestAll = os.Getenv("SPOOL_TEST_TOPIC_HEADS") == "on"
	topicHeadRead = func(ctx context.Context, s *Postgres, tenant string, q TopicQuery) ([]TopicRow, error) {
		if len(q.TaskIDs) > 0 { // since= stays on the walk (Q5), as ViewTopics serves it
			return s.walkTopicRows(ctx, tenant, q)
		}
		rows, _, err := s.headTopics(ctx, tenant, q, true)
		return rows, err
	}
}

// markBackfilled sets tenant's backfill mark, as the backfill's last chunk does.
func markBackfilled(t testing.TB, pg *Postgres, tenant string) {
	t.Helper()
	ctx := context.Background()
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO topic_head_tenants (tenant_id, backfilled_at) VALUES ($1, now())
			ON CONFLICT (tenant_id) DO UPDATE SET backfilled_at = now()`, tenant)
		return err
	}); err != nil {
		t.Fatalf("mark: %v", err)
	}
}

// TestTopicHeadReadFallsBackUntilBackfilled: with the switch on, a tenant
// with no backfill mark is read by the walk, so a topic with no head row
// still lists; once marked the heads answer (and that topic, still headless,
// is gone: the mark is what keeps it listed); a rebuild brings it back.
func TestTopicHeadReadFallsBackUntilBackfilled(t *testing.T) {
	pg := pgOnly(t)
	pg.SetTopicHeads(true)
	ctx := context.Background()
	f := seedHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
	dropHeads(f, "A")
	q := TopicQuery{Now: f.now, Lobby: f.task["lobby"]}
	listsA := func(rows []TopicRow) bool {
		for _, r := range rows {
			if r.TaskID == f.task["A"] {
				return true
			}
		}
		return false
	}
	ref, err := refTopics(ctx, pg, f.tn, q)
	f.must("reference", err)
	if !listsA(ref) {
		t.Fatal("fixture: the reference does not list A")
	}
	if _, served, err := pg.headTopics(ctx, f.tn, q, false); err != nil || served {
		t.Fatalf("unmarked tenant: served=%v err=%v, want the head read to decline", served, err)
	}
	if !TopicHeadsTestAll {
		got, err := pg.ViewTopics(ctx, f.tn, q)
		f.must("view", err)
		if d := sameRows(got, ref); d != "" || !listsA(got) {
			t.Fatalf("unmarked tenant must be the walk: %s (A listed %v)", d, listsA(got))
		}
	}
	markBackfilled(t, pg, f.tn)
	head, served, err := pg.headTopics(ctx, f.tn, q, false)
	f.must("head read", err)
	if !served || listsA(head) {
		t.Fatalf("marked tenant: served=%v, A listed=%v; want the heads, without the headless A", served, listsA(head))
	}
	f.must("rebuild", pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `SELECT topic_head_rebuild(ARRAY[$1::text], ARRAY[$2::uuid])`, f.tn, f.task["A"])
		return err
	}))
	got, err := pg.ViewTopics(ctx, f.tn, q)
	f.must("view", err)
	if d := sameRows(got, ref); d != "" {
		t.Fatalf("marked and rebuilt: head read != reference: %s", d)
	}
}

// TestTopicHeadUUIDOrder: the head walk orders by the uuid, the list and its
// cursor by task_id::text (spec 5.2). On this database's collation both
// orders agree, for random ids and the edge ids 0..., 9..., a..., f...; and
// five topics tied on last_at page one by one exactly as the walk pages them.
func TestTopicHeadUUIDOrder(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	var diff int
	if err := pg.pool.QueryRow(ctx, `WITH ids AS (
			SELECT gen_random_uuid() AS id FROM generate_series(1, 20000)
			UNION ALL SELECT x::uuid FROM unnest(ARRAY['00000000-0000-4000-8000-000000000000', '0fffffff-ffff-4fff-bfff-ffffffffffff',
				'90000000-0000-4000-8000-000000000000', '9fffffff-ffff-4fff-bfff-ffffffffffff', 'a0000000-0000-4000-8000-000000000000',
				'afffffff-ffff-4fff-bfff-ffffffffffff', 'f0000000-0000-4000-8000-000000000000', 'ffffffff-ffff-4fff-bfff-ffffffffffff']) x
		), a AS (SELECT id, row_number() OVER (ORDER BY id DESC) AS r FROM ids),
		b AS (SELECT id, row_number() OVER (ORDER BY id::text DESC) AS r FROM ids)
		SELECT count(*) FROM a JOIN b USING (r) WHERE a.id <> b.id`).Scan(&diff); err != nil {
		t.Fatal(err)
	}
	if diff != 0 {
		t.Fatalf("uuid order and task_id::text order differ at %d of 20008 ranks", diff)
	}
	f := seedHeadFix(t, pg, time.Now().UTC().Truncate(time.Microsecond))
	for i, id := range []string{"0", "9", "a", "f", "5"} {
		name := "tie" + strconv.Itoa(i)
		f.task[name] = id + "1234567-89ab-4cde-8f01-23456789abcd"
		f.line(name, name, time.Minute, lineOpt{card: true})
	}
	q := TopicQuery{Now: f.now, Lobby: f.task["lobby"], Limit: 1}
	for page := 0; page < 20; page++ {
		walk, err := pg.walkTopicRows(ctx, f.tn, q)
		f.must("walk", err)
		head, _, err := pg.headTopics(ctx, f.tn, q, true)
		f.must("head", err)
		if d := sameRows(head, walk); d != "" {
			t.Fatalf("page %d: head != walk: %s", page, d)
		}
		if len(walk) == 0 {
			return
		}
		q.BeforeAt, q.BeforeTask = walk[0].LastAt, walk[0].TaskID
	}
}

// TestTopicHeadSeededMatchesWalk: on the seeded tenant of the walk's oracle
// test (every 20th line expired, so many heads are due and take the second
// statement), the head read equals the walk on every filter combination and
// page.
func TestTopicHeadSeededMatchesWalk(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	tn := newTenant(t, pg)
	seedTopics(t, pg, tn, 3000, 300, now, 0.33)
	var parent string
	if err := pg.queryRowTenant(ctx, tn, `SELECT parent_task_id::text FROM messages
		WHERE tenant_id = $1 AND parent_task_id IS NOT NULL LIMIT 1`, []any{tn}, &parent); err != nil {
		t.Fatal(err)
	}
	var due int
	if err := pg.queryRowTenant(ctx, tn, `SELECT count(*) FROM topic_heads WHERE tenant_id = $1 AND valid_until <= $2`,
		[]any{tn, now}, &due); err != nil || due == 0 {
		t.Fatalf("the seed has %d due heads (err %v): the due statement is not exercised", due, err)
	}
	pages := 0
	for name, q := range topicQueries(now, parent) {
		for _, rd := range []string{"", "HUM-1"} {
			q := q
			q.Reader, q.ReaderChannels = rd, []string{"c1"}
			pages += comparePagesHead(t, pg, tn, name+",reader="+rd, q)
		}
	}
	t.Logf("%d pages: head read == walk; %d due heads", pages, due)
}

// comparePagesHead pages q through the walk and the head read; it returns the
// pages compared.
func comparePagesHead(t *testing.T, pg *Postgres, tn, name string, q TopicQuery) int {
	t.Helper()
	ctx := context.Background()
	for page := 1; ; page++ {
		walk, err := pg.walkTopicRows(ctx, tn, q)
		if err != nil {
			t.Fatalf("%s: walk: %v", name, err)
		}
		head, _, err := pg.headTopics(ctx, tn, q, true)
		if err != nil {
			t.Fatalf("%s: head: %v", name, err)
		}
		if d := sameRows(head, walk); d != "" {
			t.Fatalf("%s page %d: head != walk: %s", name, page, d)
		}
		if len(walk) < q.Limit {
			return page
		}
		q.BeforeAt, q.BeforeTask = walk[len(walk)-1].LastAt, walk[len(walk)-1].TaskID
	}
}

// headerVariants is the A/B of the head read's batch header (spec 5.2):
// the chosen one per shape (headHeader), both allowed, the walk's (sort and
// bitmap off), and each setting off alone.
func headerVariants(q TopicQuery) map[string]string {
	return map[string]string{
		"chosen":     headHeader(q),
		"both_on":    pgScopeTenantHeads,
		"walk":       pgScopeTenantNoJIT,
		"sort_off":   pgScopeTenantHeadsNoSort,
		"bitmap_off": pgScopeTenantHeads + `, set_config('enable_bitmapscan', 'off', true)`, // the later set_config wins
	}
}

// abShapes is one query per list shape of the A/B.
func abShapes(now time.Time, parent string) map[string]TopicQuery {
	base := TopicQuery{Now: now, Limit: 41, Roots: true}
	reader := base
	reader.Reader, reader.ReaderChannels = "HUM-1", []string{"c1"}
	shapes := map[string]TopicQuery{"all": base, "all_reader": reader}
	for name, mod := range map[string]func(q *TopicQuery){
		"channel":     func(q *TopicQuery) { q.Channel = "c1" },
		"dm":          func(q *TopicQuery) { q.DM, q.Viewer = true, "HUM-1" },
		"dm_other":    func(q *TopicQuery) { q.DM, q.Viewer = true, "AGT-2" },
		"dm_nobody":   func(q *TopicQuery) { q.DM, q.Viewer, q.Reader = true, "HUM-9", "HUM-9" },
		"dm_noreader": func(q *TopicQuery) { q.DM, q.Viewer, q.Reader, q.ReaderChannels = true, "HUM-1", "", nil },
		"agent":       func(q *TopicQuery) { q.Agent, q.AgentBox = "AGT-1", "box-a" },
		"children":    func(q *TopicQuery) { q.Parent, q.Roots = parent, false },
		"all_nonroot": func(q *TopicQuery) { q.Roots = false },
	} {
		q := reader
		mod(&q)
		shapes[name] = q
	}
	return shapes
}

// TestTopicHeadHeaderAB (SPOOL_TEST_PERF=1, ALONE: it runs the global
// Sweep; sizes SPOOL_TEST_AB_SIZES, default "20000,200000"; n =
// SPOOL_TEST_PERF_N, default 20): per shape, the head read's p50/p95 under
// each header variant, and the walk's for scale, twice - as seeded (every
// 20th line expired and still there: hundreds of due heads, the due
// statement's worst case) and after the sweep purged them (prd's state: the
// due set is about 0, spec 5.3). Every variant's rows are checked against the
// walk first.
func TestTopicHeadHeaderAB(t *testing.T) {
	if os.Getenv("SPOOL_TEST_PERF") != "1" {
		t.Skip("SPOOL_TEST_PERF=1 runs the header A/B")
	}
	pg := pgOnly(t)
	n := envInt("SPOOL_TEST_PERF_N", 20)
	sizes := os.Getenv("SPOOL_TEST_AB_SIZES")
	if sizes == "" {
		sizes = "20000,200000"
	}
	for _, sz := range splitInts(sizes) {
		ctx := context.Background()
		now := time.Now().UTC().Truncate(time.Millisecond)
		tn := newTenant(t, pg)
		seedTopics(t, pg, tn, sz, sz/12, now, 0.44)
		var parent string
		_ = pg.queryRowTenant(ctx, tn, `SELECT parent_task_id::text FROM messages
			WHERE tenant_id = $1 AND parent_task_id IS NOT NULL LIMIT 1`, []any{tn}, &parent)
		shapes := abShapes(now, parent)
		names := make([]string, 0, len(shapes))
		for k := range shapes {
			names = append(names, k)
		}
		sort.Strings(names)
		for _, phase := range []string{"seeded", "swept"} {
			if phase == "swept" {
				if _, err := pg.Sweep(ctx, now); err != nil {
					t.Fatal(err)
				}
			}
			var due int
			_ = pg.queryRowTenant(ctx, tn, `SELECT count(*) FROM topic_heads WHERE tenant_id = $1 AND valid_until <= $2`, []any{tn, now}, &due)
			for _, sh := range names {
				t.Logf("AB msgs=%d %s due=%d shape=%-11s %s", sz, phase, due, sh, abRow(t, pg, tn, shapes[sh], n))
			}
		}
	}
}

// abRow times q n times per variant (one warm-up each) and the walk.
func abRow(t *testing.T, pg *Postgres, tn string, q TopicQuery, n int) string {
	t.Helper()
	ctx := context.Background()
	walk, err := pg.walkTopicRows(ctx, tn, q)
	if err != nil {
		t.Fatal(err)
	}
	out := "walk " + timeN(n, func() error { _, err := pg.walkTopicRows(ctx, tn, q); return err })
	variants := headerVariants(q)
	for _, v := range []string{"chosen", "both_on", "walk", "sort_off", "bitmap_off"} {
		run := func() ([]TopicRow, error) {
			r := newHeadRead(tn, q, true)
			r.header = variants[v]
			b := &pgx.Batch{}
			r.queue(b)
			br := pg.pool.SendBatch(ctx, b)
			defer br.Close()
			if _, err := r.read(br); err != nil {
				return nil, err
			}
			return r.rows(), br.Close()
		}
		got, err := run()
		if err != nil {
			t.Fatalf("%s: %v", v, err)
		}
		if d := sameRows(got, walk); d != "" {
			t.Fatalf("%s: head != walk: %s", v, d)
		}
		out += " | " + v + " " + timeN(n, func() error { _, err := run(); return err })
	}
	return out
}

// timeN runs fn n times and prints p50/p95 in ms.
func timeN(n int, fn func() error) string {
	ds := make([]time.Duration, 0, n)
	for i := 0; i < n; i++ {
		t0 := time.Now()
		if err := fn(); err != nil {
			return "err " + err.Error()
		}
		ds = append(ds, time.Since(t0))
	}
	sort.Slice(ds, func(i, j int) bool { return ds[i] < ds[j] })
	ms := func(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }
	return fmt.Sprintf("p50 %.1f p95 %.1f", ms(ds[n/2]), ms(ds[(n*95+99)/100-1]))
}

func splitInts(s string) []int {
	var out []int
	cur := ""
	for _, c := range s + "," {
		if c == ',' {
			if v, err := strconv.Atoi(cur); err == nil && v > 0 {
				out = append(out, v)
			}
			cur = ""
			continue
		}
		cur += string(c)
	}
	return out
}

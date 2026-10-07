package store

import (
	"context"
	"fmt"
	"os"
	"sort"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// 027 T030: ViewTopics walks each topic's latest message instead
// of aggregating the whole tenant. The pre-027 query stays here as the oracle:
// on seeded data every filter combination must return the same rows, byte for
// byte. Postgres only (SPOOL_TEST_PG_DSN); SPOOL_TEST_PERF=1 adds the timed
// BEFORE/AFTER harness.

// viewTopicsOracle is ViewTopics as it was on trunk 2dfefe7.
func viewTopicsOracle(ctx context.Context, s *Postgres, tenant string, q TopicQuery) ([]TopicRow, error) {
	var out []TopicRow
	err := s.queryTenant(ctx, tenant, oracleTopicsSQL, []any{tenant, q.Now, q.Channel, q.Agent, optTime(q.BeforeAt), q.BeforeTask, pgLimit(q.Limit),
		q.DM, q.AgentBox, q.Viewer, q.Roots, q.Parent}, func(rows pgx.Rows) error {
		var r TopicRow
		if err := rows.Scan(&r.TaskID, &r.Channel, &r.Parent, &r.FirstAt, &r.LastAt, &r.Count,
			&r.Kinds, &r.Parties, &r.FirstMsg); err != nil {
			return err
		}
		out = append(out, r)
		return nil
	})
	return out, err
}

const oracleTopicsSQL = `WITH m AS (
			SELECT task_id::text AS task_id, msg_id::text AS msg_id, received_at, kind,
				from_id, from_box, to_id, to_box, COALESCE(channel, '') AS channel,
				COALESCE(parent_task_id::text, '') AS parent, msg
			FROM messages
			WHERE tenant_id = $1 AND expires_at > $2 AND ($3::text = '' OR channel = $3::text)
				AND (NOT $8::bool OR channel IS NULL)
		), sel AS (
			SELECT task_id FROM m GROUP BY task_id
			HAVING ($4::text = '' OR bool_or((from_id = $4::text AND ($9::text = '' OR from_box = $9::text))
					OR (to_id = $4::text AND ($9::text = '' OR to_box = $9::text))))
				AND ($10::text = '' OR bool_or(from_id = $10::text OR to_id = $10::text))
		), agg AS (
			SELECT m.task_id,
				(array_agg(m.channel ORDER BY m.received_at, m.msg_id))[1] AS channel,
				(array_agg(m.parent ORDER BY m.received_at, m.msg_id))[1] AS parent,
				min(m.received_at) AS first_at, max(m.received_at) AS last_at, count(*)::int AS n,
				array_agg(m.kind ORDER BY m.received_at, m.msg_id) AS kinds,
				array_agg(m.from_id || '@' || m.from_box) || array_agg(m.to_id || '@' || m.to_box) AS parties,
				(array_agg(m.msg ORDER BY m.received_at, m.msg_id))[1] AS first_msg
			FROM m JOIN sel ON sel.task_id = m.task_id
			GROUP BY m.task_id
		)
		SELECT task_id, channel, parent, first_at, last_at, n, kinds, parties, first_msg FROM agg
		WHERE ($5::timestamptz IS NULL OR (last_at, task_id) < ($5::timestamptz, $6::text))
			AND (NOT $11::bool OR parent = '') AND ($12::text = '' OR parent = $12::text)
		ORDER BY last_at DESC, task_id DESC
		LIMIT $7`

// seedTopics bulk-loads n messages over tasks topics into tenant, as the
// operator (one INSERT ... SELECT; InsertMessage would take minutes at 200k).
// Shape: 60% channel topics over 5 channels, 40% DMs between HUM-1, HUM-2
// and four agents; every 5th topic is a child of an earlier one; a topic's
// messages fall in a 2-day window somewhere in the last 30 days; every 20th
// message is expired; and received_at is rounded to the millisecond so ties
// (same instant, other topic or same topic) occur.
func seedTopics(t testing.TB, s *Postgres, tenant string, n, tasks int, now time.Time, seed float64) {
	t.Helper()
	ctx := context.Background()
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT setseed($1)`, seed); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `CREATE TEMP TABLE seed_tasks ON COMMIT DROP AS
			SELECT k, gen_random_uuid() AS task_id,
				CASE WHEN k % 10 < 6 THEN 'c' || (k % 5) END AS channel,
				$1::timestamptz - interval '30 days' + random() * interval '28 days' AS start_at,
				(ARRAY['HUM-1','HUM-2','AGT-1','AGT-2','AGT-3','AGT-4'])[1 + k % 6] AS a,
				(ARRAY['AGT-1','HUM-2','AGT-3','HUM-1','AGT-2','AGT-4'])[1 + (k / 6) % 6] AS b
			FROM generate_series(0, $2::int - 1) k`, now, tasks); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, parent_task_id, channel, ts,
				from_box, from_id, to_box, to_id, kind, body, files, msg, env_sig, env, received_at, expires_at)
			SELECT $1, gen_random_uuid(), st.task_id, p.task_id, st.channel, r.at,
				CASE WHEN g % 2 = 0 THEN 'box-a' ELSE 'box-b' END, CASE WHEN g % 2 = 0 THEN st.a ELSE st.b END,
				CASE WHEN g % 2 = 0 THEN 'box-b' ELSE 'box-a' END, CASE WHEN g % 2 = 0 THEN st.b ELSE st.a END,
				(ARRAY['task','result','note','reject'])[1 + g % 4], 'b', '[]',
				jsonb_build_object('v', 1, 'g', g), 'sig', '\x00'::bytea, r.at,
				CASE WHEN g % 20 = 0 THEN $2::timestamptz - interval '1 minute' ELSE r.at + interval '30 days' END
			FROM generate_series(1, $3::int) g
			CROSS JOIN LATERAL (SELECT floor(random() * $4::int)::int + 0 * g AS k, random() + 0 * g AS f) pick
			JOIN seed_tasks st ON st.k = pick.k
			LEFT JOIN seed_tasks p ON st.k % 5 = 4 AND p.k = st.k - 3
			CROSS JOIN LATERAL (SELECT date_trunc('milliseconds', st.start_at + pick.f * interval '2 days') AS at) r`,
			tenant, now, n, tasks)
		return err
	})
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := s.pool.Exec(ctx, `ANALYZE messages`); err != nil {
		t.Fatalf("analyze: %v", err)
	}
}

func pgOnly(t *testing.T) *Postgres {
	t.Helper()
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	ctx := context.Background()
	pg, err := OpenPostgres(ctx, dsn)
	if err != nil {
		t.Fatalf("postgres: %v", err)
	}
	if _, err := Migrate(ctx, pg.Pool(), sqlDir(t)); err != nil {
		t.Fatalf("migrate: %v", err)
	}
	t.Cleanup(pg.Close)
	return pg
}

// sameRows: equal rows, where parties and the first message are compared as
// the hub reads them (CLE-77960: the walk returns them pre-cut).
func sameRows(a, b []TopicRow) string {
	if len(a) != len(b) {
		return fmt.Sprintf("len %d != %d", len(a), len(b))
	}
	for i := range a {
		x, y := a[i], b[i]
		if x.TaskID != y.TaskID || x.Channel != y.Channel || x.Parent != y.Parent || !x.FirstAt.Equal(y.FirstAt) ||
			!x.LastAt.Equal(y.LastAt) || x.Count != y.Count || fmt.Sprint(x.Kinds) != fmt.Sprint(y.Kinds) ||
			fmt.Sprint(topicParties(x.Parties)) != fmt.Sprint(topicParties(y.Parties)) ||
			topicSubject(x.FirstMsg) != topicSubject(y.FirstMsg) {
			return fmt.Sprintf("row %d:\n new %+v\n old %+v", i, x, y)
		}
	}
	return ""
}

// topicQueries is every filter combination the hub sends (view.go
// handleViewTopics / handleViewChildren), plus the corner combinations.
func topicQueries(now time.Time, parent string) map[string]TopicQuery {
	out := map[string]TopicQuery{}
	for _, ch := range []string{"", "c1"} {
		for _, dm := range []bool{false, true} {
			for _, roots := range []bool{false, true} {
				for _, ag := range [][2]string{{"", ""}, {"AGT-1", ""}, {"AGT-1", "box-a"}, {"HUM-2", "box-b"}} {
					for _, viewer := range []string{"", "HUM-1"} {
						for _, par := range []string{"", parent} {
							name := fmt.Sprintf("ch=%s,dm=%v,roots=%v,agent=%s@%s,viewer=%s,parent=%v", ch, dm, roots, ag[0], ag[1], viewer, par != "")
							out[name] = TopicQuery{Channel: ch, DM: dm, Roots: roots, Agent: ag[0], AgentBox: ag[1],
								Viewer: viewer, Parent: par, Limit: 25, Now: now}
						}
					}
				}
			}
		}
	}
	return out
}

// The CONTROL: the new query returns what the oracle returns, for every
// filter combination, on every page (so the cursor pages are the oracle's:
// gapless and non-overlapping), and never an expired message or another
// tenant's topic.
func TestViewTopicsMatchesOracle(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Millisecond)
	ta, tb := newTenant(t, pg), newTenant(t, pg)
	seedTopics(t, pg, ta, 3000, 300, now, 0.11)
	seedTopics(t, pg, tb, 3000, 300, now, 0.22) // same shape, other tenant

	// A parent that has children in the seed.
	var parent string
	if err := pg.queryRowTenant(ctx, ta, `SELECT parent_task_id::text FROM messages
		WHERE tenant_id = $1 AND parent_task_id IS NOT NULL LIMIT 1`, []any{ta}, &parent); err != nil {
		t.Fatal(err)
	}
	tbTasks := map[string]bool{}
	if err := pg.queryTenant(ctx, tb, `SELECT DISTINCT task_id::text FROM messages WHERE tenant_id = $1`, []any{tb},
		func(rows pgx.Rows) error {
			var id string
			if err := rows.Scan(&id); err != nil {
				return err
			}
			tbTasks[id] = true
			return nil
		}); err != nil {
		t.Fatal(err)
	}

	pages, nonEmpty := 0, 0
	for name, q := range topicQueries(now, parent) {
		seen := map[string]bool{}
		for page := 0; ; page++ {
			got, err := pg.ViewTopics(ctx, ta, q)
			if err != nil {
				t.Fatalf("%s: %v", name, err)
			}
			want, err := viewTopicsOracle(ctx, pg, ta, q)
			if err != nil {
				t.Fatalf("%s oracle: %v", name, err)
			}
			if d := sameRows(got, want); d != "" {
				t.Fatalf("%s page %d: %s", name, page, d)
			}
			pages++
			for _, r := range got {
				if seen[r.TaskID] || tbTasks[r.TaskID] {
					t.Fatalf("%s: task %s repeated or from tenant B", name, r.TaskID)
				}
				seen[r.TaskID] = true
				if q.Viewer == "HUM-1" && !partyTo(r, "HUM-1") {
					t.Fatalf("%s: HUM-1 sees topic %s it is not party to: %v", name, r.TaskID, r.Parties)
				}
			}
			if len(got) < q.Limit {
				break
			}
			last := got[len(got)-1]
			q.BeforeAt, q.BeforeTask = last.LastAt, last.TaskID
		}
		if len(seen) > 0 {
			nonEmpty++
		}
	}
	// 128 combinations; channel+dm, and roots+parent, are empty by definition,
	// and one parent has few children: 41 are non-empty on this seed.
	if nonEmpty < 36 {
		t.Fatalf("only %d filter combinations returned rows: the seed does not exercise the filters", nonEmpty)
	}
	t.Logf("%d pages equal to the oracle, %d non-empty combinations", pages, nonEmpty)

	// Expired messages never count: the seed expires every 20th message, so
	// the unfiltered total must equal the unexpired count.
	all, err := pg.ViewTopics(ctx, ta, TopicQuery{Now: now})
	if err != nil {
		t.Fatal(err)
	}
	var live, sum int
	if err := pg.queryRowTenant(ctx, ta, `SELECT count(*) FROM messages WHERE tenant_id = $1 AND expires_at > $2`,
		[]any{ta, now}, &live); err != nil {
		t.Fatal(err)
	}
	for _, r := range all {
		sum += r.Count
	}
	if sum != live || live >= 3000 {
		t.Fatalf("topic counts sum to %d, unexpired messages %d (of 3000)", sum, live)
	}
}

func partyTo(r TopicRow, id string) bool {
	for _, p := range r.Parties {
		if len(p) > len(id) && p[:len(id)+1] == id+"@" {
			return true
		}
	}
	return false
}

// The viewer CONTROL on hand-built rows: HUM-1 never sees HUM-2's DM with an
// agent, and a topic in tenant B never shows up for tenant A.
func TestViewTopicsViewerAndTenant(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	ta, tb := newTenant(t, pg), newTenant(t, pg)
	mine, theirs, other := uuid4(), uuid4(), uuid4()
	m1 := msgFor(ta, mine, "box-b", now, now.Add(-2*time.Minute), "e1")
	m1.FromID, m1.ToID = "HUM-1", "AGT-1"
	m2 := msgFor(ta, theirs, "box-b", now, now.Add(-time.Minute), "e2")
	m2.FromID, m2.ToID = "HUM-2", "AGT-1"
	m3 := msgFor(tb, other, "box-b", now, now.Add(-time.Second), "e3")
	m3.FromID, m3.ToID = "HUM-1", "AGT-1"
	for _, m := range []Message{m1, m2, m3} {
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
	}
	got, err := pg.ViewTopics(ctx, ta, TopicQuery{DM: true, Roots: true, Viewer: "HUM-1", Limit: 10, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 1 || got[0].TaskID != mine {
		t.Fatalf("HUM-1 in tenant A: %+v", got)
	}
	got, err = pg.ViewTopics(ctx, ta, TopicQuery{DM: true, Roots: true, Limit: 10, Now: now})
	if err != nil {
		t.Fatal(err)
	}
	if len(got) != 2 || got[0].TaskID != theirs || got[1].TaskID != mine {
		t.Fatalf("tenant A, no viewer: %+v", got)
	}
}

// TestViewTopicsPerf (SPOOL_TEST_PERF=1, n = SPOOL_TEST_PERF_N, default 30)
// has two cells, each runnable alone with -run 'TestViewTopicsPerf/<cell>':
// grid (perfGrid, FR-001) and head099 (perfHeadLab, spec 099 T001c).
func TestViewTopicsPerf(t *testing.T) {
	if os.Getenv("SPOOL_TEST_PERF") != "1" {
		t.Skip("SPOOL_TEST_PERF unset")
	}
	pg := pgOnly(t)
	runs := 30
	if v, _ := strconv.Atoi(os.Getenv("SPOOL_TEST_PERF_N")); v > 0 {
		runs = v
	}
	now := time.Now().UTC().Truncate(time.Millisecond)
	var ver string
	_ = pg.pool.QueryRow(context.Background(), `SHOW server_version`).Scan(&ver)
	t.Logf("pg %s, n=%d per cell", ver, runs)
	t.Run("grid", func(t *testing.T) { perfGrid(t, pg, runs, now) })
	t.Run("head099", func(t *testing.T) { perfHeadLab(t, pg, runs, now) })
}

// perfGrid is the FR-001 harness: 2 tenants x {5k, 50k, 200k} messages over
// 2k topics, ViewTopics limit 50 (the hub asks for limit+1), first page and a
// deep cursor page (after topic 1000), p50/p95 over n runs, for the oracle
// (BEFORE) and the live query (AFTER).
func perfGrid(t *testing.T, pg *Postgres, runs int, now time.Time) {
	ctx := context.Background()
	type impl struct {
		name string
		fn   func(context.Context, *Postgres, string, TopicQuery) ([]TopicRow, error)
	}
	impls := []impl{{"before", viewTopicsOracle}, {"after", func(ctx context.Context, s *Postgres, tn string, q TopicQuery) ([]TopicRow, error) {
		return s.ViewTopics(ctx, tn, q)
	}}}
	// The brief's grid holds 2k topics, so a bigger tenant is also a longer
	// topic (2.5 -> 100 messages); the last row holds the topic length at
	// 2.5 instead, to separate the two.
	for _, sz := range []struct{ size, tasks int }{{5000, 2000}, {50000, 2000}, {200000, 2000}, {200000, 80000}} {
		size := sz.size
		ta, tb := newTenant(t, pg), newTenant(t, pg)
		seedTopics(t, pg, ta, size, sz.tasks, now, 0.3)
		seedTopics(t, pg, tb, size, sz.tasks, now, 0.4)
		for _, qc := range []struct {
			name string
			q    TopicQuery
		}{
			{"all-roots", TopicQuery{Roots: true}},
			{"channel", TopicQuery{Channel: "c1", Roots: true}},
			{"dm-viewer", TopicQuery{DM: true, Roots: true, Viewer: "HUM-1"}},
		} {
			q := qc.q
			q.Now, q.Limit = now, 51
			// deep cursor: the 1000th topic of this filter (or its last one)
			deep := q
			deep.Limit = 1000
			rows, err := viewTopicsOracle(ctx, pg, ta, deep)
			if err != nil || len(rows) == 0 {
				t.Fatalf("deep cursor: %v %d", err, len(rows))
			}
			deep = q
			deep.BeforeAt, deep.BeforeTask = rows[len(rows)-1].LastAt, rows[len(rows)-1].TaskID
			depth := len(rows)
			for _, page := range []struct {
				name string
				q    TopicQuery
			}{{"first", q}, {fmt.Sprintf("deep@%d", depth), deep}} {
				for _, im := range impls {
					var ds []time.Duration
					for i := 0; i < runs+2; i++ {
						t0 := time.Now()
						if _, err := im.fn(ctx, pg, ta, page.q); err != nil {
							t.Fatal(err)
						}
						if i >= 2 { // two warm-up runs
							ds = append(ds, time.Since(t0))
						}
					}
					sort.Slice(ds, func(i, j int) bool { return ds[i] < ds[j] })
					p50, p95 := ds[len(ds)/2], ds[(len(ds)*95+99)/100-1]
					t.Logf("PERF size=%d topics=%d filter=%s page=%s impl=%s n=%d p50=%.2fms p95=%.2fms", size, sz.tasks, qc.name,
						page.name, im.name, len(ds), ms(p50), ms(p95))
				}
			}
		}
	}
}

func ms(d time.Duration) float64 { return float64(d.Microseconds()) / 1000 }

// perfHeadLab is spec 099 T001c: claude-4's lab (099 claude-4-opinion.md
// section 2) as a committed cell, so the phase 1 / phase 2 numbers can be
// re-run. One tenant, seedTopics(22 000 messages, 1 500 topics), then one
// archived line in each of 380 topics (prd had 388 archived cards). Per list
// shape, three reads of the same page:
//   - walk: today's ViewTopics;
//   - head: the narrow head (phase 1: the walk key per topic and per channel
//     part, headLab) walked in key order, plus today's summary();
//   - key: the same head walk with no summary at all, the floor that a stored
//     summary (phase 2) could reach.
//
// The head reads reuse the builder's own probes (walkParties, readerDoor,
// walkTree, archivedTopicHideSQL), so they differ from today's only in the
// walk, and their rows must equal the walk's before anything is timed.
// Every read runs under pgScopeTenantNoJIT, n runs after 3 warm-ups.
func perfHeadLab(t *testing.T, pg *Postgres, runs int, now time.Time) {
	ctx := context.Background()
	tn := newTenant(t, pg)
	seedTopics(t, pg, tn, 22000, 1500, now, 0.5)
	archiveLabTopics(t, pg, tn, now, 380)
	lab := newHeadLab(t, pg, tn, now)
	for _, sh := range headLabShapes(now) {
		walk, err := pg.ViewTopics(ctx, tn, sh.q)
		if err != nil || len(walk) == 0 {
			t.Fatalf("%s: walk %v, %d rows", sh.name, err, len(walk))
		}
		head, err := lab.read(ctx, pg, tn, sh.q, true)
		if err != nil {
			t.Fatalf("%s: head: %v", sh.name, err)
		}
		if d := sameRows(head, walk); d != "" {
			t.Fatalf("%s: head != walk: %s", sh.name, d)
		}
		key, err := lab.read(ctx, pg, tn, sh.q, false)
		if err != nil {
			t.Fatalf("%s: key: %v", sh.name, err)
		}
		if d := sameKeys(key, walk); d != "" {
			t.Fatalf("%s: key != walk: %s", sh.name, d)
		}
		for _, v := range []struct {
			name string
			fn   func() error
		}{
			{"walk", func() error { _, err := pg.ViewTopics(ctx, tn, sh.q); return err }},
			{"head", func() error { _, err := lab.read(ctx, pg, tn, sh.q, true); return err }},
			{"key", func() error { _, err := lab.read(ctx, pg, tn, sh.q, false); return err }},
		} {
			p50, p95, err := timeCell(runs, v.fn)
			if err != nil {
				t.Fatalf("%s %s: %v", sh.name, v.name, err)
			}
			t.Logf("PERF099 shape=%s limit=%d variant=%s rows=%d n=%d p50=%.2fms p95=%.2fms", sh.name, sh.q.Limit,
				v.name, len(walk), runs, ms(p50), ms(p95))
		}
	}
}

// headLabShapes are the lab's four list shapes, as the hub sends them (roots
// only, no issue talk); the reader reads its DMs and channel c1.
func headLabShapes(now time.Time) []struct {
	name string
	q    TopicQuery
} {
	rd, mine := "HUM-1", []string{"c1"}
	shapes := []struct {
		name string
		q    TopicQuery
	}{
		{"dm-reader", TopicQuery{DM: true, Reader: rd, ReaderChannels: mine, Limit: 51}},
		{"all-reader", TopicQuery{Reader: rd, ReaderChannels: mine, Limit: 51}},
		{"channel-c1", TopicQuery{Channel: "c1", Limit: 21}},
		{"dm-peer-AGT-1", TopicQuery{DM: true, Agent: "AGT-1", Reader: rd, ReaderChannels: mine, Limit: 21}},
	}
	for i := range shapes {
		shapes[i].q.Roots, shapes[i].q.NoIssues, shapes[i].q.Now = true, true, now
	}
	return shapes
}

// archiveLabTopics archives the first line of n topics of tenant.
func archiveLabTopics(t *testing.T, pg *Postgres, tenant string, now time.Time, n int) {
	t.Helper()
	ctx := context.Background()
	err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE messages SET archived_at = $2, archived_by = 'HUM-1'
			WHERE tenant_id = $1 AND msg_id IN (SELECT DISTINCT ON (task_id) msg_id FROM messages
				WHERE tenant_id = $1 AND expires_at > $2 ORDER BY task_id, received_at LIMIT $3)`, tenant, now, n)
		return err
	})
	if err != nil {
		t.Fatalf("archive: %v", err)
	}
}

// headLab is the narrow head of spec 099 section 3 as two lab tables, built
// once by GROUP BY over the tenant's unexpired lines: nh holds one row per
// topic (its latest line, and its latest DM line), nhp one row per channel
// part (the latest line in that channel). They are lab tables, dropped after
// the cell: no RLS, and the column is "tenant", not tenant_id, so a crashed
// run never leaves a table the tenant_id RLS catalogue gate would read.
type headLab struct{ nh, nhp string }

func newHeadLab(t *testing.T, pg *Postgres, tenant string, now time.Time) headLab {
	t.Helper()
	ctx := context.Background()
	sfx := strconv.FormatInt(time.Now().UnixNano(), 36)
	lab := headLab{nh: "lab099_nh_" + sfx, nhp: "lab099_nhp_" + sfx}
	t.Cleanup(func() {
		_, _ = pg.pool.Exec(context.Background(), `DROP TABLE IF EXISTS `+lab.nh+`, `+lab.nhp)
	})
	ddl := `CREATE UNLOGGED TABLE ` + lab.nh + ` (tenant text NOT NULL, task_id uuid NOT NULL,
			last_at timestamptz NOT NULL, dm_last_at timestamptz, PRIMARY KEY (tenant, task_id));
		CREATE INDEX ON ` + lab.nh + ` (tenant, last_at DESC, task_id DESC);
		CREATE INDEX ON ` + lab.nh + ` (tenant, dm_last_at DESC, task_id DESC) WHERE dm_last_at IS NOT NULL;
		CREATE UNLOGGED TABLE ` + lab.nhp + ` (tenant text NOT NULL, task_id uuid NOT NULL, channel text NOT NULL,
			last_at timestamptz NOT NULL, PRIMARY KEY (tenant, task_id, channel));
		CREATE INDEX ON ` + lab.nhp + ` (tenant, channel, last_at DESC, task_id DESC)`
	if _, err := pg.pool.Exec(ctx, ddl); err != nil {
		t.Fatalf("head lab ddl: %v", err)
	}
	err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO `+lab.nh+` SELECT tenant_id, task_id, max(received_at),
				max(received_at) FILTER (WHERE channel IS NULL)
			FROM messages WHERE tenant_id = $1 AND expires_at > $2 GROUP BY tenant_id, task_id`, tenant, now); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO `+lab.nhp+` SELECT tenant_id, task_id, channel, max(received_at)
			FROM messages WHERE tenant_id = $1 AND expires_at > $2 AND channel IS NOT NULL
			GROUP BY tenant_id, task_id, channel`, tenant, now)
		return err
	})
	if err != nil {
		t.Fatalf("head lab fill: %v", err)
	}
	if _, err := pg.pool.Exec(ctx, `ANALYZE `+lab.nh+`; ANALYZE `+lab.nhp); err != nil {
		t.Fatalf("head lab analyze: %v", err)
	}
	return lab
}

// read is one page of q through the head: with summary, the rows of
// ViewTopics; without it, only each listed topic's id and walk key (LastAt).
func (lab headLab) read(ctx context.Context, pg *Postgres, tenant string, q TopicQuery, summary bool) ([]TopicRow, error) {
	sql, args := lab.sql(tenant, q, summary)
	var out []TopicRow
	each := scanTopicRows(&out)
	if !summary {
		each = func(rows pgx.Rows) error {
			var r TopicRow
			if err := rows.Scan(&r.TaskID, &r.LastAt); err != nil {
				return err
			}
			out = append(out, r)
			return nil
		}
	}
	err := pg.queryTenantNoJIT(ctx, tenant, sql, args, each)
	return out, err
}

// sql is statement() with the walk over the head instead of messages: the
// key is the topic's latest line in the shape's lane (all, DM, or the
// channel's part), so the "is this the topic's latest line" probe is gone,
// and the cursor is on the uuid (spec 099: same order as task_id::text).
// No page cursor: the lab times first pages.
func (lab headLab) sql(tenant string, q TopicQuery, summary bool) (string, []any) {
	b := &topicsSQL{c: &sqlc{}, q: q}
	b.tn, b.now = b.c.arg(tenant), b.c.arg(q.Now)
	from, key, walk := lab.nh, "l.last_at", "l.tenant = "+b.tn
	switch {
	case q.Channel != "":
		from, walk = lab.nhp, walk+" AND l.channel = "+b.c.arg(q.Channel)
	case q.DM:
		key, walk = "l.dm_last_at", walk+" AND l.dm_last_at IS NOT NULL"
	}
	door, aggDoor := b.readerDoor()
	walk += b.walkParties() + door + b.walkTree() + archivedTopicHideSQL("l", b.tn, b.c.arg(q.Lobby))
	lim := b.c.arg(pgLimit(q.Limit))
	order := " ORDER BY " + key + " DESC, l.task_id DESC LIMIT 1"
	w := `WITH RECURSIVE w (task_id, received_at, n) AS (
			(SELECT l.task_id, ` + key + `, 1 FROM ` + from + ` l WHERE ` + walk + order + `)
			UNION ALL
			SELECT s.task_id, s.received_at, w.n + 1 FROM w CROSS JOIN LATERAL (
				SELECT l.task_id, ` + key + ` AS received_at FROM ` + from + ` l
				WHERE ` + walk + ` AND (` + key + `, l.task_id) < (w.received_at, w.task_id)` + order + `
			) s
			WHERE w.n < ` + lim + `
		)`
	if !summary {
		return w + ` SELECT w.task_id::text, w.received_at FROM w ORDER BY w.received_at DESC, w.task_id DESC`, b.c.args
	}
	return w + b.summary(aggDoor), b.c.args
}

// sameKeys: the same topics in the same order, with the same walk key.
func sameKeys(a, b []TopicRow) string {
	if len(a) != len(b) {
		return fmt.Sprintf("len %d != %d", len(a), len(b))
	}
	for i := range a {
		if a[i].TaskID != b[i].TaskID || !a[i].LastAt.Equal(b[i].LastAt) {
			return fmt.Sprintf("row %d: %s@%s != %s@%s", i, a[i].TaskID, a[i].LastAt, b[i].TaskID, b[i].LastAt)
		}
	}
	return ""
}

// timeCell is fn's p50 and p95 over runs timed runs, after 3 warm-ups.
func timeCell(runs int, fn func() error) (p50, p95 time.Duration, err error) {
	var ds []time.Duration
	for i := 0; i < runs+3; i++ {
		t0 := time.Now()
		if err := fn(); err != nil {
			return 0, 0, err
		}
		if i >= 3 {
			ds = append(ds, time.Since(t0))
		}
	}
	sort.Slice(ds, func(i, j int) bool { return ds[i] < ds[j] })
	return ds[len(ds)/2], ds[(len(ds)*95+99)/100-1], nil
}

// TestViewTopicsExplain prints EXPLAIN (ANALYZE, BUFFERS) of the oracle and
// the live query for SPOOL_TEST_EXPLAIN_TENANT (a tenant the perf harness
// seeded), first page and the cursor SPOOL_TEST_EXPLAIN_BEFORE=<rfc3339>/<task>.
func TestViewTopicsExplain(t *testing.T) {
	tn := os.Getenv("SPOOL_TEST_EXPLAIN_TENANT")
	if tn == "" {
		t.Skip("SPOOL_TEST_EXPLAIN_TENANT unset")
	}
	pg := pgOnly(t)
	ctx := context.Background()
	now := time.Now().UTC()
	for _, qc := range []struct {
		name string
		q    TopicQuery
	}{
		{"all-roots", TopicQuery{Roots: true}},
		{"channel", TopicQuery{Channel: "c1", Roots: true}},
		{"dm-viewer", TopicQuery{DM: true, Roots: true, Viewer: "HUM-1"}},
	} {
		q := qc.q
		q.Now, q.Limit = now, 51
		if b := os.Getenv("SPOOL_TEST_EXPLAIN_BEFORE"); b != "" {
			at, task, _ := strings.Cut(b, "/")
			q.BeforeAt, _ = time.Parse(time.RFC3339Nano, at)
			q.BeforeTask = task
		}
		newSQL, newArgs := viewTopicsSQL(tn, q)
		for _, im := range []struct {
			name string
			sql  string
			args []any
		}{
			{"before", oracleTopicsSQL, []any{tn, q.Now, q.Channel, q.Agent, optTime(q.BeforeAt), q.BeforeTask, pgLimit(q.Limit),
				q.DM, q.AgentBox, q.Viewer, q.Roots, q.Parent}},
			{"after", newSQL, newArgs},
		} {
			var plan []string
			if err := pg.queryTenantNoJIT(ctx, tn, "EXPLAIN (ANALYZE, BUFFERS) "+im.sql, im.args, func(rows pgx.Rows) error {
				var line string
				if err := rows.Scan(&line); err != nil {
					return err
				}
				plan = append(plan, line)
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			t.Logf("EXPLAIN filter=%s impl=%s\n%s", qc.name, im.name, strings.Join(plan, "\n"))
		}
	}
}

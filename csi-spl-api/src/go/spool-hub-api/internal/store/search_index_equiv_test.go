package store

import (
	"context"
	"fmt"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/search"
)

// Spec 100 T008 (section 6: T6, T7, T8) on Postgres: the index path (the
// probe of spool_search_candidates, rdb 0143) and the scan path (the kill
// switch, SearchQuery.ScanOnly) return the same rows in the same order, on
// every page, for every search-v1 form, below and above the cap, and again
// after each write that changes what a search can find. T6: another tenant's
// rows, seeded with the same words, never come back on either path.

// equivRows is the corpus size: "common" is in every row, so above the cap
// (searchIndexCap = 500); the other words are each in at most ~40 rows.
const equivRows = 620

// equivSeed seeds one tenant's corpus: 3 messages per topic, received_at
// ties within a topic (the msg_id tie-break), kinds, senders, channels
// (DM = NULL), a parent for some topics, files and code blocks, and the
// test words: zulu (every 40th), the phrase "kilo lima" (every 30th) and its
// reverse "lima kilo" (every 45th), quebec (every 25th, the prefix queb),
// foo (every 33rd) and bar (every 37th).
func equivSeed(t *testing.T, pg *Postgres, tid string, now time.Time) {
	t.Helper()
	ctx := context.Background()
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, parent_task_id, ts, from_box, from_id,
				to_box, to_id, kind, body, files, msg, env_sig, env, received_at, expires_at, channel)
			SELECT $1, gen_random_uuid(), md5($1 || 'topic' || (i / 3))::uuid,
				CASE WHEN (i / 3) % 13 = 0 AND i > 2 THEN md5($1 || 'topic0')::uuid END,
				$2::timestamptz - i * interval '1 minute', 'box-a',
				CASE WHEN i % 3 = 0 THEN 'HUM-2' ELSE 'GRK-03' END, 'box-b', 'CLE-07',
				(ARRAY['note', 'task', 'result', 'msg', 'blocker'])[i % 5 + 1],
				'common ' || md5(i::text)
					|| CASE WHEN i % 40 = 0 THEN ' zulu' ELSE '' END
					|| CASE WHEN i % 30 = 0 THEN ' kilo lima' ELSE '' END
					|| CASE WHEN i % 45 = 0 THEN ' lima kilo' ELSE '' END
					|| CASE WHEN i % 25 = 0 THEN ' quebec' ELSE '' END
					|| CASE WHEN i % 33 = 0 THEN ' foo' ELSE '' END
					|| CASE WHEN i % 37 = 0 THEN ' bar' ELSE '' END
					|| CASE WHEN i % 17 = 0 THEN E'\n`+"```"+`x`+"```"+`' ELSE '' END,
				CASE WHEN i % 9 = 0 THEN '[{"name":"a.txt","kind":"file","bytes":3}]' ELSE '[]' END::jsonb,
				'{"v":1}', 'sig', '\x00', $2::timestamptz - (i / 3) * interval '1 minute',
				$2::timestamptz + interval '30 days',
				CASE WHEN i % 11 = 0 THEN NULL WHEN i % 7 = 0 THEN 'ops' ELSE 'lobby' END
			FROM generate_series(1, $3::int) i`, tid, now, equivRows)
		return err
	}); err != nil {
		t.Fatal(err)
	}
}

// equivQuery is one query of the matrix; above: its candidates exceed the
// cap (the id filter must not apply); probe: it has an AND-chain text term.
type equivQuery struct {
	text         string
	probe, above bool
}

// equivQueries: T8's search-v1 forms, then T7's mixed queries (text with
// NOT, from:, in:, is:, has:), each below the cap (zulu, queb) and above it
// (common).
var equivQueries = []equivQuery{
	{"zulu ", true, false},
	{`"kilo lima" `, true, false},
	{"queb", true, false},
	{"zulu common ", true, false},
	{"foo OR bar", false, false},
	{"foo OR zulu", false, false},
	{"-zulu", false, false},
	{"common ", true, true},
	{"common -zulu ", true, true},
	{"zulu -kilo ", true, false},
	{"zulu from:HUM-2 ", true, false},
	{"common from:HUM-2 ", true, true},
	{"zulu in:lobby ", true, false},
	{"common in:ops ", true, true},
	{"common in:dm ", true, true},
	{"common -in:lobby ", true, true},
	{"zulu is:note ", true, false},
	{"common is:result ", true, true},
	{"common -is:task ", true, true},
	{"has:file queb", true, false},
	{"common has:file ", true, true},
	{"common has:code ", true, true},
}

// walkMessages pages SearchMessages to the end through one path:
// chronological (keyset) or by relevance (offset); each row as a string
// that starts with its msg id.
func walkMessages(t *testing.T, pg *Postgres, tid string, base SearchQuery, scanOnly, rel bool, limit int) []string {
	t.Helper()
	q := base
	q.ScanOnly, q.Relevance, q.Limit, q.Budget = scanOnly, rel, limit, 10*time.Second
	var out []string
	for page := 0; page < 400; page++ {
		rows, err := pg.SearchMessages(context.Background(), tid, q)
		if err != nil {
			t.Fatalf("messages scanOnly=%v rel=%v: %v", scanOnly, rel, err)
		}
		for _, r := range rows {
			out = append(out, fmt.Sprint(r.MsgID, " ", r.TaskID, r.Channel, r.Kind, r.Body, r.FromID, r.ReceivedAt.UnixNano()))
		}
		if len(rows) < q.Limit {
			return out
		}
		last := rows[len(rows)-1]
		q.AfterAt, q.AfterID, q.Offset = last.ReceivedAt, last.MsgID, q.Offset+len(rows)
	}
	t.Fatal("messages: paging did not end")
	return nil
}

// walkTopics pages SearchTopics to the end through one path.
func walkTopics(t *testing.T, pg *Postgres, tid string, base SearchQuery, scanOnly bool, limit int) []string {
	t.Helper()
	q := base
	q.ScanOnly, q.Limit, q.Budget = scanOnly, limit, 10*time.Second
	var out []string
	for page := 0; page < 400; page++ {
		rows, err := pg.SearchTopics(context.Background(), tid, q)
		if err != nil {
			t.Fatalf("topics scanOnly=%v: %v", scanOnly, err)
		}
		for _, r := range rows {
			out = append(out, fmt.Sprint(r.TaskID, r.Title, r.Count, r.LastAt.UnixNano(), r.Channel, r.Parent, r.Kinds, r.Parties))
		}
		if len(rows) < q.Limit {
			return out
		}
		last := rows[len(rows)-1]
		q.AfterAt, q.AfterID = last.LastAt, last.TaskID
	}
	t.Fatal("topics: paging did not end")
	return nil
}

// equivProbe checks one query's probe decision: built exactly when it has an
// AND-chain text term, and the id filter applies exactly at or below the cap.
func equivProbe(t *testing.T, pg *Postgres, tid string, base SearchQuery, eq equivQuery, stage string) {
	t.Helper()
	if _, _, ok := candidateProbeSQL(base, searchIndexCap, search.OpText); ok != eq.probe {
		t.Fatalf("%s %q: probe built=%v, want %v", stage, eq.text, ok, eq.probe)
	}
	ids, err := pg.searchCandidates(context.Background(), tid, base, searchIndexCap, search.OpText)
	if err != nil {
		t.Fatalf("%s %q: probe: %v", stage, eq.text, err)
	}
	if filtered := ids != nil; eq.probe && filtered == eq.above {
		t.Fatalf("%s %q: id filter=%v (%d ids) but above cap=%v", stage, eq.text, filtered, len(ids), eq.above)
	}
}

// equivCheck runs the matrix once: for every query the probe decision is
// the expected one, and messages (chronological and by relevance) and
// topics are equal on both paths and not empty. It returns the index path's
// chronological message rows per query, for the write checks.
func equivCheck(t *testing.T, pg *Postgres, tid string, now time.Time, stage string) map[string][]string {
	t.Helper()
	got := map[string][]string{}
	for _, eq := range equivQueries {
		base := sq(t, eq.text, now)
		equivProbe(t, pg, tid, base, eq, stage)
		limit := 7 // several keyset pages through the id filter
		if eq.above || !eq.probe {
			limit = 60
		}
		for _, rel := range []bool{false, true} {
			scan, idx := walkMessages(t, pg, tid, base, true, rel, limit), walkMessages(t, pg, tid, base, false, rel, limit)
			if len(scan) == 0 || !slices.Equal(scan, idx) {
				t.Fatalf("%s %q rel=%v: index path %d rows != scan path %d rows", stage, eq.text, rel, len(idx), len(scan))
			}
			if !rel {
				got[eq.text] = idx
			}
		}
		// has: applies to messages only: a topic search with it is empty
		scan, idx := walkTopics(t, pg, tid, base, true, limit), walkTopics(t, pg, tid, base, false, limit)
		if (len(scan) == 0) != strings.Contains(eq.text, "has:") || !slices.Equal(scan, idx) {
			t.Fatalf("%s %q: topics index path %d != scan path %d", stage, eq.text, len(idx), len(scan))
		}
	}
	return got
}

// hasMsg reports whether rows (walkMessages strings) carry msgID.
func hasMsg(rows []string, msgID string) bool {
	return slices.ContainsFunc(rows, func(r string) bool { return strings.HasPrefix(r, msgID+" ") })
}

// zuluRows returns the msg ids of n live channel rows of tid whose body says
// zulu (with) or does not (!with), never kilo, newest first.
func zuluRows(t *testing.T, pg *Postgres, tid string, with bool, n int) []string {
	t.Helper()
	ctx := context.Background()
	var out []string
	err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT msg_id::text FROM messages WHERE tenant_id = $1
			AND (strpos(body, 'zulu') > 0) = $2 AND strpos(body, 'kilo') = 0 AND channel IS NOT NULL
			ORDER BY received_at DESC, msg_id DESC LIMIT $3`, []any{tid, with, n}, func(rows pgx.Rows) error {
			var id string
			if err := rows.Scan(&id); err != nil {
				return err
			}
			out = append(out, id)
			return nil
		})
	})
	if err != nil || len(out) != n {
		t.Fatalf("zuluRows(%v): %d of %d, %v", with, len(out), n, err)
	}
	return out
}

// equivStep is one write of TestSearchIndexEquivalence and the row whose
// zulu match it changes: wanted is whether "zulu " finds it afterwards.
type equivStep struct {
	name   string
	write  func()
	id     string
	wanted bool
}

// TestSearchIndexEquivalence is spec 100 T7 and T8: the full matrix on a
// fixed corpus, then again after edit, delete, expiry, archive, move and
// merge; each write is also seen (or no longer seen) by the index path, so
// the equality is not between two equally stale answers. T6: tenant B holds
// the same words and none of its rows comes back for A on either path.
func TestSearchIndexEquivalence(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	if !pg.hasSearchIndex(ctx) {
		t.Fatal("rdb 0143 spool_search_candidates not found by the probe")
	}
	tid, other := newTenant(t, pg), newTenant(t, pg)
	equivSeed(t, pg, tid, now)
	equivSeed(t, pg, other, now)
	equivNoOtherTenant(t, pg, tid, other, now)
	equivCheck(t, pg, tid, now, "seed")
	for _, s := range equivSteps(t, pg, tid, now) {
		s.write()
		got := equivCheck(t, pg, tid, now, s.name)
		if hasMsg(got["zulu "], s.id) != s.wanted {
			t.Fatalf("%s: index path shows %s=%v, want %v", s.name, s.id, !s.wanted, s.wanted)
		}
	}
	equivNoOtherTenant(t, pg, tid, other, now)
}

// equivSteps are the writes of T8 on tid's corpus: an edit that adds zulu
// and one that drops it, a delete, an expiry, an archive, a move into
// another topic and channel, and a merge whose kept row takes zulu.
func equivSteps(t *testing.T, pg *Postgres, tid string, now time.Time) []equivStep {
	ctx := context.Background()
	in, out := zuluRows(t, pg, tid, true, 6), zuluRows(t, pg, tid, false, 3)
	edit := func(id, body string) {
		_, err := pg.ApplyEdit(ctx, tid, id, Edit{Body: body, Msg: []byte(`{"v":1}`), Env: []byte(`{}`),
			EditedBy: "CLE-07", EditedAt: now})
		equivDo(t, err)
	}
	return []equivStep{
		{"edit adds zulu", func() { edit(out[0], "common zulu after an edit") }, out[0], true},
		{"edit drops zulu", func() { edit(in[0], "common no longer the word") }, in[0], false},
		{"delete", func() { equivDo(t, pg.DeleteMessage(ctx, tid, in[1])) }, in[1], false},
		{"expiry", func() { equivExpire(t, pg, tid, in[2], now) }, in[2], false},
		{"archive", func() { _, err := pg.SetArchived(ctx, tid, in[3], "HUM-2", now, true); equivDo(t, err) }, in[3], false},
		{"move", func() { equivMove(t, pg, tid, in[4], out[1], now) }, in[4], true},
		{"merge drops", func() { equivMerge(t, pg, tid, out[2], in[5], now) }, in[5], false},
		{"merge keeps", func() {}, out[2], true},
	}
}

func equivDo(t *testing.T, err error) {
	t.Helper()
	if err != nil {
		t.Fatal(err)
	}
}

// equivExpire moves one row's expires_at into the past (the sweep has not
// run: the row is still there, and both paths must hide it).
func equivExpire(t *testing.T, pg *Postgres, tid, id string, now time.Time) {
	t.Helper()
	equivDo(t, pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), `UPDATE messages SET expires_at = $3 WHERE tenant_id = $1 AND msg_id = $2`,
			tid, id, now.Add(-time.Second))
		return err
	}))
}

// equivMove moves id into the topic of dest, in channel ops.
func equivMove(t *testing.T, pg *Postgres, tid, id, dest string, now time.Time) {
	t.Helper()
	ctx := context.Background()
	var task string
	equivDo(t, pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT task_id::text FROM messages WHERE tenant_id = $1 AND msg_id = $2`, tid, dest).Scan(&task)
	}))
	_, err := pg.MoveMessage(ctx, tid, id, task, "ops", "HUM-2", now, now)
	equivDo(t, err)
}

// equivMerge merges drop into keep: keep's body takes drop's word.
func equivMerge(t *testing.T, pg *Postgres, tid, keep, drop string, now time.Time) {
	t.Helper()
	_, err := pg.MergeMessages(context.Background(), tid, keep, drop, Edit{Body: "common merged zulu",
		Msg: []byte(`{"v":1}`), Env: []byte(`{}`), EditedBy: "HUM-2", EditedAt: now})
	equivDo(t, err)
}

// equivNoOtherTenant is T6 at the store level: for every query of the
// matrix, on both paths, A's answer and A's probe carry none of B's msg ids.
// CONTROL: B's own search finds its rows.
func equivNoOtherTenant(t *testing.T, pg *Postgres, tid, other string, now time.Time) {
	t.Helper()
	ctx := context.Background()
	theirs := map[string]bool{}
	equivDo(t, pg.inTenant(ctx, other, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT msg_id::text FROM messages WHERE tenant_id = $1`, []any{other}, func(rows pgx.Rows) error {
			var id string
			err := rows.Scan(&id)
			theirs[id] = true
			return err
		})
	}))
	if len(theirs) != equivRows {
		t.Fatalf("control: tenant B holds %d rows, want %d", len(theirs), equivRows)
	}
	for _, eq := range equivQueries {
		base := sq(t, eq.text, now)
		ids, err := pg.searchCandidates(ctx, tid, base, searchIndexCap, search.OpText)
		equivDo(t, err)
		if slices.ContainsFunc(ids, func(id string) bool { return theirs[id] }) {
			t.Fatalf("%q: probe for A returned a row of B", eq.text)
		}
		for _, scanOnly := range []bool{false, true} {
			for _, r := range walkMessages(t, pg, tid, base, scanOnly, false, 200) {
				if theirs[strings.SplitN(r, " ", 2)[0]] {
					t.Fatalf("%q scanOnly=%v: A's search returned B's row %s", eq.text, scanOnly, r)
				}
			}
		}
	}
	if rows := walkMessages(t, pg, other, sq(t, "zulu ", now), false, false, 200); len(rows) == 0 {
		t.Fatal("control: B's own zulu search found nothing")
	}
}

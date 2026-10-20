package store

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// SPL-2705: the Flow counts' headless probe (flowHeadlessSQL: does this
// channel line's topic still have a live card in its channel?) matched the
// topic as h.task_id = coalesce(parent_task_id, task_id). Under row-level
// security Postgres keeps a qual it cannot prove leakproof behind the policy
// quals, and a CoalesceExpr is never proven so, so task_id was a Filter and
// never an index key: prd read messages_channel and filtered every line of
// the channel for the topic's card. 2026-10-20, flow_counts for t1: 49 loops
// at 12.4 ms, 1 959 rows removed per loop, 85 790 of the statement's 94 046
// buffers; 08:26..09:32Z, while the DB's storage was slow, 43 of the 106
// statement timeouts. The same choice written as CASE is an index key.

// headlessProbe is the probe alone, once per live channel line of the last
// hour (prd ran it for 49 lines, the rest decided by the other rules), under
// the tenant scope the hub reads with. It stays behind an OR, as in
// flowCoveredSQL, so the planner keeps it a per-line SubPlan (a bare NOT
// EXISTS would become an anti-join, a plan prd never ran).
func headlessProbe(channel string) string {
	return `SELECT count(*) FROM messages m WHERE m.tenant_id = $1 AND m.channel = '` + channel + `' AND m.expires_at > $2
		AND m.received_at > $2::timestamptz - interval '1 hour'
		AND (m.kind = 'never'` + flowHeadlessSQL("m", "m", "$2::timestamptz", "$3::text") + `)`
}

// seedBusyChannel plants prd's shape: topics in one channel, a card
// (is_parent 1) and replies (is_parent 0) each, every 4th topic a sub-thread
// of the one before it (parent_task_id), plus channel-less lines that keep
// the column default (is_parent 1). VACUUM as prd's autovacuum does: with no
// visibility map the planner prices every index probe as a heap read.
func seedBusyChannel(t *testing.T, pg *Postgres, tenant, channel string, topics, replies int, now time.Time) {
	t.Helper()
	ctx := context.Background()
	err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, parent_task_id, channel, ts, from_box, from_id,
				to_box, to_id, kind, body, files, msg, env_sig, env, received_at, expires_at, is_parent)
			SELECT $1, gen_random_uuid(), md5($1 || k)::uuid, CASE WHEN k % 4 = 2 THEN md5($1 || (k - 1))::uuid END,
				CASE WHEN k % 4 = 3 THEN NULL ELSE $2 END, now(),
				'box-a', 'HUM-1', 'box-b', 'AGT-1', 'note', 'b', '[]', '{}'::jsonb, 'sig', '\x00'::bytea,
				$3::timestamptz - make_interval(mins => k * 7 + g), $3::timestamptz + interval '30 days',
				CASE WHEN g = 0 OR k % 4 = 3 THEN 1 ELSE 0 END
			FROM generate_series(0, $4::int - 1) k CROSS JOIN generate_series(0, $5::int) g`,
			tenant, channel, now, topics, replies)
		return err
	})
	if err != nil {
		t.Fatalf("seed: %v", err)
	}
	if _, err := pg.pool.Exec(ctx, `VACUUM ANALYZE messages`); err != nil {
		t.Fatal(err)
	}
}

// probeScans returns every scan of the probe's alias h as "<index or node>
// x<loops> cond=<index cond>", and the rows its filter removed in all.
func probeScans(t *testing.T, pg *Postgres, tenant, sql string, args []any) ([]string, int) {
	t.Helper()
	ctx := context.Background()
	var raw []byte
	if err := pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `EXPLAIN (ANALYZE, FORMAT JSON) `+sql, args...).Scan(&raw)
	}); err != nil {
		t.Fatal(err)
	}
	type node struct {
		Type    string `json:"Node Type"`
		Alias   string `json:"Alias"`
		Index   string `json:"Index Name"`
		Cond    string `json:"Index Cond"`
		Loops   int    `json:"Actual Loops"`
		Removed int    `json:"Rows Removed by Filter"`
		Plans   []node `json:"Plans"`
	}
	var doc []struct {
		Plan node `json:"Plan"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil || len(doc) == 0 {
		t.Fatalf("plan: %v", err)
	}
	var scans []string
	removed := 0
	var walk func(n node)
	walk = func(n node) {
		if n.Alias == "h" {
			what := n.Index
			if what == "" {
				what = n.Type
			}
			scans = append(scans, fmt.Sprintf("%s x%d cond=%s", what, n.Loops, n.Cond))
			removed += n.Removed * max(n.Loops, 1)
		}
		for _, c := range n.Plans {
			walk(c)
		}
	}
	walk(doc[0].Plan)
	return scans, removed
}

// TestFlowHeadlessProbeKeysOnTopic: per channel line, the probe finds the
// topic's card by an index key on task_id, so it reads the topic's rows, not
// the channel's; it finds every card (no line of the seed is headless) and,
// CONTROL, a topic whose card expired is counted, its replies and the
// replies of its sub-thread (their card is the parent topic's).
func TestFlowHeadlessProbeKeysOnTopic(t *testing.T) {
	pg := pgOnly(t)
	now := time.Now().UTC().Truncate(time.Millisecond)
	tn := newTenant(t, pg)
	const topics, replies = 400, 10
	seedBusyChannel(t, pg, tn, "devel", topics, replies, now)
	for i := 0; i < 7; i++ {
		seedBusyChannel(t, pg, newTenant(t, pg), "devel", 5, 2, now)
	}
	args := []any{tn, now, uuid4()}
	scans, removed := probeScans(t, pg, tn, headlessProbe("devel"), args)
	if len(scans) == 0 {
		t.Fatalf("no scan of the probe's messages h in the plan")
	}
	for _, s := range scans {
		if !strings.Contains(s, "task_id = CASE") {
			t.Errorf("the headless probe is not keyed on its topic: %v (filter removed %d rows)", scans, removed)
			break
		}
	}
	count := func() int {
		t.Helper()
		var n int
		if err := pg.queryTenant(context.Background(), tn, headlessProbe("devel"), args, func(r pgx.Rows) error { return r.Scan(&n) }); err != nil {
			t.Fatal(err)
		}
		return n
	}
	if n := count(); n != 0 {
		t.Fatalf("%d lines read as headless, want 0: every topic of the seed has its card", n)
	}
	// topic 1's card expires: its replies (received 8..17 min ago) and those
	// of topic 2, its sub-thread (15..24 min ago, card = topic 1's), are
	// headless; topic 2's own is_parent 1 line is in the same window.
	if err := pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), `UPDATE messages SET expires_at = $2::timestamptz - interval '1 minute'
			WHERE tenant_id = $1 AND task_id = md5($1 || 1)::uuid AND is_parent = 1`, tn, now)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if n, want := count(), 2*replies+1; n != want {
		t.Fatalf("CONTROL: %d lines read as headless after topic 1's card expired, want %d", n, want)
	}
}

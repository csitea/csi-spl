package store

import (
	"context"
	"fmt"
	"regexp"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Perf round 5, P5-11 (t1 eafc9b15): prd planned the Flow page of a member
// with 6 633 of 8 853 flow_events at rows=29 (the RLS current_setting OR and
// expires_at > now() hide the member's share), so it ran a Seq Scan on
// flow_events and probed messages_pkey plus the door for every one of the
// 6 633 events before it took the top 201: 2.1 s cold. The page now walks the
// member's events in index order and joins messages one event at a time, so
// the LIMIT stops the walk after the page (plus the door misses it skips).

// flowFoldSQLBeforeP511 is flowFoldSQL as it was before P5-11: the CONTROL
// the new form is compared with, row for row.
func flowFoldSQLBeforeP511() string {
	return `WITH raw AS (SELECT ` + flowEventCols("e", "m", "$3", "$9::text") + `, e.at AS ev_at
			FROM flow_events e JOIN messages m ON m.tenant_id = e.tenant_id AND m.msg_id = e.msg_id
			WHERE e.tenant_id = $1 AND e.member_id = $2 AND e.expires_at > $3 AND m.expires_at > $3` + flowDoorSQL("e", "m", "$4::text[]") + `
			  AND ($6::timestamptz IS NULL OR (e.at, e.msg_id) < ($6::timestamptz, $7::uuid))
			  AND ($8::text[] IS NULL OR e.kind = ANY($8::text[]))
			ORDER BY e.at DESC, e.msg_id DESC LIMIT $5),
		tt AS (SELECT d.task_id,
				coalesce((SELECT left(r.body, 400) FROM messages r WHERE r.tenant_id = $1 AND r.task_id = d.task_id::uuid
					ORDER BY r.received_at, r.msg_id LIMIT 1), '') AS title,
				coalesce((SELECT i.number FROM issues i WHERE i.tenant_id = $1 AND i.task_id = d.task_id::uuid), 0) AS issue
			FROM (SELECT DISTINCT task_id FROM raw) d)
		SELECT raw.*, tt.title, tt.issue FROM raw JOIN tt ON tt.task_id = raw.task_id ORDER BY raw.ev_at DESC, raw.msg_id DESC`
}

// seedFlowMember plants prd's shape on top of seedTopics. The hub writes an
// event for a member who may read the message, so member gets one event per
// message of #c1, #c3 and its DMs, newest first, n of them; the door drops an
// event only when the member's access changed later: here #c2 was archived,
// and its events older than 15 days are the door misses. A second member
// gets others events; every 7th topic is archived (its lines are read) and
// every 11th topic carries a t: read mark.
func seedFlowMember(t *testing.T, pg *Postgres, tenant, member, other string, n, others int, now time.Time) {
	t.Helper()
	ctx := context.Background()
	err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		for _, q := range []struct {
			sql  string
			args []any
		}{
			{`INSERT INTO flow_events (tenant_id, member_id, msg_id, task_id, kind, at, expires_at)
				SELECT tenant_id, $2, msg_id, task_id, (ARRAY['mention','dm','reply','poke'])[1 + abs(hashtext(msg_id::text)) % 4],
					received_at, expires_at FROM messages
				WHERE tenant_id = $1 AND (channel IN ('c1', 'c3') OR channel IS NULL AND $2 IN (from_id, to_id)
					OR channel = 'c2' AND received_at < $4::timestamptz - interval '15 days')
				ORDER BY received_at DESC, msg_id DESC LIMIT $3`, []any{tenant, member, n, now}},
			{`INSERT INTO flow_events (tenant_id, member_id, msg_id, task_id, kind, at, expires_at)
				SELECT tenant_id, $2, msg_id, task_id, 'mention', received_at, expires_at
				FROM messages WHERE tenant_id = $1 ORDER BY received_at, msg_id LIMIT $3`, []any{tenant, other, others}},
			{`INSERT INTO channels (tenant_id, channel_id, name, created_by, archived_at)
				SELECT $1, c, c, 'HUM-9', CASE WHEN c = 'c2' THEN $2::timestamptz END FROM unnest(ARRAY['c0','c1','c2','c3','c4']) c`, []any{tenant, now}},
			{`INSERT INTO channel_humans (tenant_id, channel_id, human_id) SELECT $1, c, $2 FROM unnest(ARRAY['c1','c2','c3']) c`, []any{tenant, member}},
			{`UPDATE messages m SET archived_at = $2 FROM (SELECT DISTINCT task_id FROM messages WHERE tenant_id = $1) d
				WHERE m.tenant_id = $1 AND m.task_id = d.task_id AND abs(hashtext(d.task_id::text)) % 7 = 0
				  AND m.msg_id = (SELECT x.msg_id FROM messages x WHERE x.tenant_id = $1 AND x.task_id = d.task_id ORDER BY x.received_at LIMIT 1)`, []any{tenant, now}},
			{`INSERT INTO read_marks (tenant_id, member_id, mark_key, at, msg_id)
				SELECT $1, $2, 't:' || d.task_id, $3, '' FROM (SELECT DISTINCT task_id FROM messages WHERE tenant_id = $1) d
				WHERE abs(hashtext(d.task_id::text)) % 11 = 0`, []any{tenant, member, now}},
		} {
			if _, err := tx.Exec(ctx, q.sql, q.args...); err != nil {
				return fmt.Errorf("%.60s: %w", q.sql, err)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatalf("seed flow: %v", err)
	}
	for _, tb := range []string{"messages", "flow_events", "read_marks", "channel_humans"} {
		if _, err := pg.pool.Exec(ctx, "ANALYZE "+tb); err != nil {
			t.Fatal(err)
		}
	}
}

// seedFlowTenants plants prd's tenant spread: n more tenants with a few
// flow_events each. With one tenant the planner reads the RLS predicate
// tenant_id = current_setting(...) as true for every row; with prd's eight it
// reads about 0.5% (prd: EXPLAIN of the bare table, rows=43 of 8 857), which
// is what hid the member's 6 633 events from the planner.
func seedFlowTenants(t *testing.T, pg *Postgres, n int, now time.Time) {
	t.Helper()
	ctx := context.Background()
	for i := 0; i < n; i++ {
		tid := newTenant(t, pg)
		m := msgFor(tid, uuid4(), "box-b", now, now, "env-"+uuid4())
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO flow_events (tenant_id, member_id, msg_id, task_id, kind, at, expires_at)
				SELECT $1, 'HUM-' || k, $2, $3, 'mention', $4, $5 FROM generate_series(1, 5) k`, tid, m.MsgID, m.TaskID, now, m.ExpiresAt)
			return err
		}); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := pg.pool.Exec(ctx, "ANALYZE flow_events"); err != nil {
		t.Fatal(err)
	}
}

// flowFoldRows runs sql (prefix "EXPLAIN ..." or "") under the tenant scope
// the hub reads with, or under the operator scope (where the planner reads
// the RLS predicate as prd misread it for the tenant), and returns every row
// as one string.
func flowFoldRows(t *testing.T, pg *Postgres, tenant string, operator bool, prefix, sql string, args []any) []string {
	t.Helper()
	ctx := context.Background()
	var out []string
	each := func(r pgx.Rows) error {
		v, err := r.Values()
		out = append(out, fmt.Sprint(v))
		return err
	}
	var err error
	if operator {
		err = pg.asOperator(ctx, func(tx pgx.Tx) error { return eachRow(ctx, tx, prefix+sql, args, each) })
	} else {
		err = pg.queryTenant(ctx, tenant, prefix+sql, args, each)
	}
	if err != nil {
		t.Fatal(err)
	}
	return out
}

var flowSeqScanRe = regexp.MustCompile(`Seq Scan on flow_events \w+ .*\(actual time`)

// TestFlowFoldStopsAtPage: a member with 6 633 events. The page must equal
// the CONTROL (the form before P5-11) row for row on the first page, on a
// cursor page among the door misses (the refill) and on a kind page. The
// first page's plan must probe messages for the page only, not for every
// event, and under the hub's tenant scope must not run a Seq Scan on
// flow_events. CONTROL: under prd's
// misestimate (the operator scope) the old form probes messages once per
// event, so the test can see the plan it replaces.
func TestFlowFoldStopsAtPage(t *testing.T) {
	pg := pgOnly(t)
	now := time.Now().UTC().Truncate(time.Millisecond)
	tn := newTenant(t, pg)
	const member, events = "HUM-1", 6633
	seedTopics(t, pg, tn, 18000, 3000, now, 0.37)
	seedFlowMember(t, pg, tn, member, "HUM-2", events, 2220, now)
	seedFlowTenants(t, pg, 7, now)

	page := func(before time.Time, beforeID string, kinds []string) []any {
		var b, bid any
		if beforeID != "" {
			b, bid = before, beforeID
		}
		return []any{tn, member, now, PublicChannels, FlowFoldWindow + 1, b, bid, kinds, ""}
	}
	first := flowFoldRows(t, pg, tn, false, "", flowFoldSQLBeforeP511(), page(time.Time{}, "", nil))
	if len(first) != FlowFoldWindow+1 {
		t.Fatalf("CONTROL first page has %d rows, want %d: the seed is too thin", len(first), FlowFoldWindow+1)
	}
	var curAt time.Time
	var curID string
	var misses int
	if err := pg.queryTenant(context.Background(), tn, `SELECT at, msg_id::text,
			(SELECT count(*) FILTER (WHERE m.channel = 'c2') FROM (SELECT x.msg_id FROM flow_events x WHERE x.tenant_id = $1 AND x.member_id = $2
				AND (x.at, x.msg_id) < (e.at, e.msg_id) ORDER BY x.at DESC, x.msg_id DESC LIMIT $3) w JOIN messages m ON m.tenant_id = $1 AND m.msg_id = w.msg_id)
		FROM flow_events e WHERE tenant_id = $1 AND member_id = $2 ORDER BY at DESC, msg_id DESC OFFSET 5000 LIMIT 1`,
		[]any{tn, member, FlowFoldWindow + 1}, func(r pgx.Rows) error { return r.Scan(&curAt, &curID, &misses) }); err != nil {
		t.Fatal(err)
	}
	if misses == 0 {
		t.Fatalf("the cursor page holds no door miss: the refill is not tested")
	}
	cases := map[string][]any{
		"first":  page(time.Time{}, "", nil),
		"cursor": page(curAt, curID, nil),
		"kind":   page(time.Time{}, "", flowKindsFilter(FlowMention)),
	}
	for name, args := range cases {
		got, want := flowFoldRows(t, pg, tn, false, "", flowFoldSQL(), args), flowFoldRows(t, pg, tn, false, "", flowFoldSQLBeforeP511(), args)
		if len(want) == 0 || strings.Join(got, "\n") != strings.Join(want, "\n") {
			t.Errorf("%s: %d rows differ from the CONTROL's %d", name, len(got), len(want))
			for i := 0; i < len(got) && i < len(want); i++ {
				if got[i] != want[i] {
					t.Errorf("%s: first difference at row %d:\n got %s\nwant %s", name, i, got[i], want[i])
					break
				}
			}
		}
	}

	const explain = "EXPLAIN (ANALYZE) "
	for _, operator := range []bool{false, true} {
		plan := strings.Join(flowFoldRows(t, pg, tn, operator, explain, flowFoldSQL(), cases["first"]), "\n")
		if n := probeLoops(strings.Split(plan, "\n"), "messages m"); n == 0 || n > FlowFoldWindow+1 {
			t.Errorf("operator=%v: the messages probe ran %d times, want 1..%d (the page):\n%s", operator, n, FlowFoldWindow+1, plan)
		}
		// Under the operator scope the planner believes ~0.5% of the rows
		// and may cut ev by a Seq Scan and a top-N sort of flow_events, as
		// prd does (145 pages, 5 ms): flow_events only, never messages. The
		// hub reads under the tenant scope, where it must walk the index.
		if !operator && flowSeqScanRe.MatchString(plan) {
			t.Errorf("the page ran a Seq Scan on flow_events, want the flow_events_member_at walk:\n%s", plan)
		}
	}
	ctl := flowFoldRows(t, pg, tn, true, explain, flowFoldSQLBeforeP511(), cases["first"])
	if n := probeLoops(ctl, "messages m"); n <= events/2 {
		t.Errorf("CONTROL the old form probed messages %d times, want > %d (the test cannot see the old plan):\n%s", n, events/2, strings.Join(ctl, "\n"))
	}
}

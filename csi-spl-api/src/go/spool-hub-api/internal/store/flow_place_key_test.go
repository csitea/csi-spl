package store

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// flowPlaceMismatchSQL counts the events of tenant $1 whose stored place_key /
// cov_at (rdb 0137) differ from their message, by flowCountsSQL's own place
// expression (not the migration's function), and all the tenant's events.
// The same read proves the prd backfill.
const flowPlaceMismatchSQL = `SELECT count(*) FILTER (WHERE fe.place_key IS DISTINCT FROM
		CASE WHEN m.channel IS NOT NULL THEN 'ch:' || m.channel
			WHEN coalesce(m.from_box, '') <> '' THEN 'dm:' || m.from_id || '@' || m.from_box
			ELSE 'dm:' || m.from_id END
		OR fe.cov_at IS DISTINCT FROM m.received_at), count(*)
	FROM flow_events fe JOIN messages m ON m.tenant_id = fe.tenant_id AND m.msg_id = fe.msg_id
	WHERE fe.tenant_id = $1`

// API perf ap-01a (rdb 0137): every Flow event stores its place key and its
// coverage time, written with the line and kept current when a line is moved
// or its topic merged, and the event's `at` (the f:seen clock) never moves.
// A mark, a move and a merge each leave 0 mismatches against the messages,
// and FlowRead (today's statement) sees the same places the rows store.
func TestFlowPlaceKey0137(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	base := time.Now().UTC().Truncate(time.Microsecond)
	tid := newTenant(t, pg)
	n := 0
	post := func(card int, from, fromBox, to, channel, task, body string) Message {
		t.Helper()
		n++
		at := base.Add(time.Duration(n) * time.Second)
		m := msgFor(tid, task, "box-a", at, at, "env-"+uuid4())
		m.FromID, m.FromBox, m.ToID, m.Channel, m.Body = from, fromBox, to, channel, body
		m.IsParent = card
		if _, err := pg.InsertMessage(ctx, m); err != nil {
			t.Fatal(err)
		}
		return m
	}
	now := base.Add(time.Hour)
	keys := func() map[string]int {
		t.Helper()
		p, err := pg.FlowRead(ctx, FlowQuery{Tenant: tid, Member: "HUM-1", Now: now})
		if err != nil {
			t.Fatal(err)
		}
		return p.Keys
	}
	// ats: every event's `at`, keyed member/msg_id.
	ats := func() map[string]time.Time {
		t.Helper()
		out := map[string]time.Time{}
		err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
			rows, err := tx.Query(ctx, `SELECT member_id || '/' || msg_id::text, at FROM flow_events WHERE tenant_id = $1`, tid)
			if err != nil {
				return err
			}
			defer rows.Close()
			for rows.Next() {
				var k string
				var at time.Time
				if err := rows.Scan(&k, &at); err != nil {
					return err
				}
				out[k] = at
			}
			return rows.Err()
		})
		if err != nil {
			t.Fatal(err)
		}
		return out
	}
	before := map[string]time.Time{}
	events := 0 // the tenant's events, fixed after the inserts
	check := func(step string) {
		t.Helper()
		var bad, all int
		if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, flowPlaceMismatchSQL, tid).Scan(&bad, &all)
		}); err != nil {
			t.Fatal(err)
		}
		if events == 0 {
			events = all
		}
		if bad != 0 || all != events || all < 6 {
			t.Fatalf("%s: %d of %d events mismatch their message, want 0 of %d (6+)", step, bad, all, events)
		}
		for k, at := range ats() {
			if was, ok := before[k]; ok && !was.Equal(at) {
				t.Fatalf("%s: event %s at moved %v -> %v", step, k, was, at)
			}
			before[k] = at
		}
	}

	T, U, D, E := uuid4(), uuid4(), uuid4(), uuid4()
	c := post(1, "HUM-2", "box-wui", "", "lobby", T, "@HUM-1 card")     // mention: HUM-1 watches T
	r1 := post(0, "c-034", "box-a", "", "lobby", T, "agent reply")      // reply
	post(0, "c-034", "box-a", "", "lobby", T, "second reply")           // reply
	u := post(1, "HUM-3", "box-wui", "", "feedback", U, "@HUM-1 other") // mention in feedback (public)
	post(1, "c-034", "box-a", "HUM-1", "", D, "agent dm")               // dm:c-034@box-a
	post(1, "HUM-2", "", "HUM-1", "", E, "dm with no box")              // dm:HUM-2
	check("insert")
	k := keys()
	if k["ch:lobby"] != 3 || k["ch:feedback"] != 1 || k["dm:c-034@box-a"] != 1 || k["dm:HUM-2"] != 1 {
		t.Fatalf("insert: keys %v", k)
	}

	// A hub older than flowInsertCTE's keys inserts NULLs: the trigger fills them.
	if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `WITH d AS (DELETE FROM flow_events WHERE tenant_id = $1 AND msg_id = $2::uuid RETURNING *)
			INSERT INTO flow_events (tenant_id, member_id, msg_id, task_id, kind, at, expires_at)
			SELECT tenant_id, member_id, msg_id, task_id, kind, at, expires_at FROM d`, tid, u.MsgID)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	check("old-hub insert")

	// Mark: the channel row is read up to r1; the stored keys do not change.
	if err := pg.SaveReadMarks(ctx, tid, "HUM-1", map[string]ReadMark{"ch:lobby": {At: r1.ReceivedAt, MsgID: r1.MsgID}}, now); err != nil {
		t.Fatal(err)
	}
	check("mark")
	if k = keys(); k["ch:lobby"] != 1 {
		t.Fatalf("mark: keys %v", k)
	}

	// Move r1 into U in feedback, past its own time: place and cov_at follow, at stays.
	if _, err := pg.MoveMessage(ctx, tid, r1.MsgID, U, "feedback", "HUM-1", base.Add(30*time.Second), base.Add(20*time.Second)); err != nil {
		t.Fatal(err)
	}
	check("move")
	if k = keys(); k["ch:lobby"] != 1 || k["ch:feedback"] != 2 {
		t.Fatalf("move: keys %v", k)
	}

	// Merge T (the card and its remaining reply) into U in feedback.
	if _, err := pg.MergeTopic(ctx, tid, c.MsgID, T, U, "feedback", "HUM-1", base.Add(40*time.Second)); err != nil {
		t.Fatal(err)
	}
	check("merge")
	if k = keys(); k["ch:lobby"] != 0 || k["ch:feedback"] != 4 {
		t.Fatalf("merge: keys %v", k)
	}
}

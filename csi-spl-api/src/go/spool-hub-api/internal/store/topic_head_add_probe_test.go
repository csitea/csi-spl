package store

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Perf round 5, row P5-02 (rdb 0182): the insert path of the topic heads is
// index probes only. Before 0182 the first line of a new topic fell into
// topic_head_rebuild, which seq-scanned every message, and the add's head
// fold seq-scanned every topic_head_parts row. This test counts the drain's
// seq scans on the three tables (pg_stat_xact_user_tables, this
// transaction only) for each insert shape, and checks the heads it wrote
// against a rebuild (topic_head_diff). Postgres only (SPOOL_TEST_PG_DSN).

// drainSeqScans inserts one line of f's tenant into task (a DM line when
// dm), fires the deferred head drain at once, and returns the seq scans the
// drain alone made on messages, topic_heads and topic_head_parts. It commits.
func drainSeqScans(t *testing.T, f *headFix, task, msgID string, dm bool) int64 {
	t.Helper()
	ctx := context.Background()
	scans := `SELECT coalesce(sum(seq_scan), 0) FROM pg_stat_xact_user_tables
		WHERE relname IN ('messages', 'topic_heads', 'topic_head_parts')`
	var before, after int64
	ch, to := any(ChannelLobby), "HUM-1"
	if dm {
		ch = nil
	}
	f.must("insert "+msgID, f.pg.inTenant(ctx, f.tn, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id,
				kind, body, msg, env_sig, env, received_at, expires_at)
			VALUES ($1, $2, $3, $4, $5::timestamptz, 'box-a', 'AGT-1', 'box-wui', $6, 'task', 'probe line', '{}', 'sig', '\x00', $5::timestamptz, $5::timestamptz + interval '30 days')`,
			f.tn, msgID, task, ch, f.t0, to); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, scans).Scan(&before); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `SET CONSTRAINTS topic_head_apply IMMEDIATE`); err != nil {
			return err
		}
		return tx.QueryRow(ctx, scans).Scan(&after)
	}))
	return after - before
}

// TestTopicHeadAddProbes: see the file comment.
func TestTopicHeadAddProbes(t *testing.T) {
	pg := pgOnly(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	f := lightHeadFix(t, pg, now)
	// Enough rows that a whole-table read is never the planner's best plan
	// for one topic: a seq scan here is the shape, not a small-table pick.
	seedTopics(t, pg, f.tn, 4000, 400, now.Add(-time.Hour), 0.17)
	backfillTenant(f, true)
	if _, err := pg.pool.Exec(ctx, `ANALYZE messages, topic_heads, topic_head_parts`); err != nil {
		t.Fatal(err)
	}
	if d := headDiff(f); len(d) != 0 {
		t.Fatalf("after the seed's backfill: %d heads differ", len(d))
	}
	var existing string
	f.must("a seeded topic", pg.asOperator(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT task_id::text FROM topic_heads WHERE tenant_id = $1 ORDER BY task_id LIMIT 1`, f.tn).Scan(&existing)
	}))

	// A card row that left its topic and is archived hides the topic named by
	// its msg_id: a NEW topic of that id must start hidden (card_archived).
	cardTask := uuid4()
	f.task["C"] = cardTask
	moved := uuid4()
	f.must("an archived card elsewhere", pg.inTenant(ctx, f.tn, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, channel, ts, from_box, from_id, to_box, to_id,
				kind, body, msg, env_sig, env, received_at, expires_at, archived_at)
			VALUES ($1, $2, $3, $4, $5::timestamptz, 'box-a', 'AGT-1', 'box-wui', 'HUM-1', 'task', 'card', '{}', 'sig', '\x00', $5::timestamptz, $5::timestamptz + interval '30 days', $5::timestamptz)`,
			f.tn, cardTask, moved, ChannelLobby, now.Add(-time.Minute))
		return err
	}))

	for _, c := range []struct {
		what, task string
		dm         bool
	}{
		{"a line in an existing topic", existing, false},
		{"the first line of a new channel topic", uuid4(), false},
		{"the first line of a new DM topic", uuid4(), true},
		{"the first line of a new topic whose card is archived elsewhere", cardTask, false},
	} {
		if n := drainSeqScans(t, f, c.task, uuid4(), c.dm); n != 0 {
			t.Errorf("%s: the head drain made %d seq scans, want 0 (index probes only)", c.what, n)
		}
	}
	if d := headDiff(f); len(d) != 0 {
		t.Fatalf("after the probe inserts: heads differ from a rebuild: %v", d)
	}
	if h := readHead(f, "C"); !h.card || h.archived != 0 || h.rev != 1 {
		t.Errorf("new topic under an archived card: head %+v, want card_archived, 0 archived rows, rev 1", h)
	}

	// A real miss (a topic with older lines and no head) is still rebuilt.
	f.must("lose a head", pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM topic_heads WHERE tenant_id = $1 AND task_id = $2`, f.tn, existing)
		return err
	}))
	drainSeqScans(t, f, existing, uuid4(), false)
	if d := headDiff(f); len(d) != 0 {
		t.Fatalf("after an insert into a topic whose head was lost: heads differ from a rebuild: %v", d)
	}
}

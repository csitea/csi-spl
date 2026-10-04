package store

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// sweepMarkBufferBudget bounds the shared buffers one flowMarkSweepSQL chunk
// may touch over the seeded tenant below (perf edition 20261004, E01). With
// the msg_id computed before the anti-join, each f: mark is one index probe
// into messages; with the CASE inside NOT EXISTS (the old text) RLS keeps the
// non-leakproof key off the index, and every mark filters the tenant's whole
// messages table (the old text ran past 9 min on this seed; the new one
// touched 1.5k..2.4k buffers in 5..16 ms, n=3). statement_timeout makes the
// old shape fail in seconds rather than hang the suite.
const sweepMarkBufferBudget = 10000

// TestFlowMarkSweepPostgres (Postgres, SPOOL_TEST_PG_DSN): the sweep deletes
// exactly the f:<msg_id> marks whose message is gone (a uuid key with no row,
// a key that is no uuid at all) and keeps f:seen, a live line's mark and
// every non-f: mark; one chunk stays within sweepMarkBufferBudget.
func TestFlowMarkSweepPostgres(t *testing.T) {
	pg := perfStore(t, "")
	ctx := context.Background()
	tid := perfTenant(t, pg)
	t.Cleanup(func() {
		_ = pg.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = $1`, tid)
			return err
		})
	})
	now := time.Now().UTC().Truncate(time.Second)
	const msgs, live, gone, junk = 9000, 100, 100, 50
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, ts, from_box, from_id,
			to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at)
			SELECT $1, gen_random_uuid(), gen_random_uuid(), $2, 'box-a', 'CLE-01', 'box-b', 'CLE-02',
				'note', 'sweep body ' || g, '{"v":1}', 'sig', convert_to(repeat('x', 400) || g, 'UTF8'), $2, $3
			FROM generate_series(1, $4) g`, tid, now.Add(-time.Hour), now.Add(30*24*time.Hour), msgs); err != nil {
			return err
		}
		marks := []string{
			`SELECT 'f:' || msg_id::text FROM messages WHERE tenant_id = $1 LIMIT ` + fmt.Sprint(live),
			`SELECT 'f:' || gen_random_uuid()::text FROM generate_series(1, ` + fmt.Sprint(gone) + `)`,
			`SELECT 'f:not-a-uuid-' || g FROM generate_series(1, ` + fmt.Sprint(junk) + `) g`,
			`SELECT 'f:seen'`,
			`SELECT 'ch:general'`,
		}
		for _, m := range marks {
			if _, err := tx.Exec(ctx, `INSERT INTO read_marks (tenant_id, member_id, mark_key, at, updated_at)
				SELECT $1, 'HUM-1', k, $2, $2 FROM (`+m+`) AS s(k)`, tid, now.Add(-time.Minute)); err != nil {
				return err
			}
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.pool.Exec(ctx, `ANALYZE messages; ANALYZE read_marks`); err != nil {
		t.Fatal(err)
	}

	// One chunk, measured in a rolled-back transaction.
	errRollback := errors.New("rollback")
	var plan []struct {
		Plan struct {
			SharedHit  int `json:"Shared Hit Blocks"`
			SharedRead int `json:"Shared Read Blocks"`
		} `json:"Plan"`
		ExecutionTime float64 `json:"Execution Time"`
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		var raw []byte
		if _, err := tx.Exec(ctx, `SET LOCAL statement_timeout = '20s'`); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) `+flowMarkSweepSQL, now, sweepChunk).Scan(&raw); err != nil {
			return err
		}
		if err := json.Unmarshal(raw, &plan); err != nil {
			return err
		}
		return errRollback
	}); !errors.Is(err, errRollback) {
		t.Fatal(err)
	}
	buffers := plan[0].Plan.SharedHit + plan[0].Plan.SharedRead
	t.Logf("PERF flow mark sweep: messages=%d marks=%d shared buffers=%d exec=%.2f ms", msgs, live+gone+junk+2, buffers, plan[0].ExecutionTime)
	if buffers > sweepMarkBufferBudget {
		t.Fatalf("one sweep chunk touched %d shared buffers, budget %d: the anti-join filters messages per mark again", buffers, sweepMarkBufferBudget)
	}

	if _, err := pg.Sweep(ctx, now); err != nil {
		t.Fatal(err)
	}
	var kept, fLive int
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*), count(*) FILTER (WHERE mark_key LIKE 'f:%' AND mark_key <> 'f:seen')
			FROM read_marks WHERE tenant_id = $1`, tid).Scan(&kept, &fLive)
	}); err != nil {
		t.Fatal(err)
	}
	if fLive != live || kept != live+2 {
		t.Fatalf("after the sweep %d marks (%d live f:), want %d (the %d live f: + f:seen + ch:)", kept, fLive, live+2, live)
	}
}

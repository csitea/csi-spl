package store

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// The two "which tenants lack their hub card" reads (the #public notice, rdb
// 0173; the Issue backlog topic, rdb 0194) run on every retention sweep of
// every hub instance. Under the operator RLS scope the planner keeps a key
// computed by a non-leakproof function (sha256, encode) off the index, so
// each NOT EXISTS probe filtered the tenant's messages one by one: prd
// 2026-10-22 (prd incident follow-up, SPL-2868, n=3), public notice 71..292 ms
// and 1 777 buffers for 18 tenants, backlog 174..238 ms and 4 788 buffers for 750
// links, and 1.9..5.5 s mean in Query Insights while the shared-core DB
// stalled. Each reads messages by its primary key now.
func TestMissingHubCardsProbeByPrimaryKey(t *testing.T) {
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
	const msgs, issues = 3000, 40
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `INSERT INTO messages (tenant_id, msg_id, task_id, ts, from_box, from_id,
			to_box, to_id, kind, body, msg, env_sig, env, received_at, expires_at)
			SELECT $1, gen_random_uuid(), gen_random_uuid(), $2, 'box-a', 'CLE-01', 'box-b', 'CLE-02',
				'note', 'card body ' || g, '{"v":1}', 'sig', convert_to(repeat('x', 400) || g, 'UTF8'), $2, $3
			FROM generate_series(1, $4) g`, tid, now.Add(-time.Hour), now.Add(30*24*time.Hour), msgs); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO issue_counters (tenant_id, last_number) VALUES ($1, $2)`, tid, issues); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, `INSERT INTO issues (tenant_id, number, title, task_id, created_by, updated_by)
			SELECT $1, g, 'i', gen_random_uuid(), 'HUM-1', 'HUM-1' FROM generate_series(1, $2) g`, tid, issues); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `INSERT INTO issue_discussions (tenant_id, number, task_id, linked_by, linked_at)
			SELECT $1, g, spool_issue_backlog_id($1), 'HUM-1', $3 FROM generate_series(1, $2) g`, tid, issues, now)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.pool.Exec(ctx, `ANALYZE messages; ANALYZE issue_discussions; ANALYZE tenants`); err != nil {
		t.Fatal(err)
	}

	for _, c := range []struct {
		name string
		sql  string
		args []any
		read func(context.Context) ([]string, error)
	}{
		{"public notice", publicNoticeMissingSQL, []any{SystemTenant}, pg.TenantsMissingPublicNotice},
		{"issue backlog", issueBacklogMissingSQL, nil, pg.TenantsMissingIssueBacklog},
	} {
		got, err := c.read(ctx)
		if err != nil || !contains(got, tid) {
			t.Fatalf("%s: %v %v, want %s in it", c.name, got, err, tid)
		}
		probes, buffers, ms := messagesProbes(t, pg, c.sql, c.args)
		t.Logf("PERF %s: messages=%d shared buffers=%d exec=%.2f ms probes=%v", c.name, msgs, buffers, ms, probes)
		if len(probes) == 0 {
			t.Fatalf("%s: no read of messages in the plan", c.name)
		}
		for _, p := range probes {
			if p != "messages_pkey" {
				t.Fatalf("%s reads messages by %q, want messages_pkey: the key is computed inside the probe, so RLS keeps it off the index and the tenant's messages are filtered one by one", c.name, p)
			}
		}
	}
}

// messagesProbes runs EXPLAIN ANALYZE of sql under the operator scope in a
// rolled-back transaction: the index (or "Seq Scan") of each messages node,
// the statement's shared buffers and its time.
func messagesProbes(t *testing.T, pg *Postgres, sql string, args []any) ([]string, int, float64) {
	t.Helper()
	ctx := context.Background()
	type node struct {
		NodeType   string          `json:"Node Type"`
		Relation   string          `json:"Relation Name"`
		Index      string          `json:"Index Name"`
		SharedHit  int             `json:"Shared Hit Blocks"`
		SharedRead int             `json:"Shared Read Blocks"`
		Plans      json.RawMessage `json:"Plans"`
	}
	var plan []struct {
		Plan          json.RawMessage `json:"Plan"`
		ExecutionTime float64         `json:"Execution Time"`
	}
	errRollback := errors.New("rollback")
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		var raw []byte
		if _, err := tx.Exec(ctx, `SET LOCAL statement_timeout = '20s'`); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `EXPLAIN (ANALYZE, BUFFERS, FORMAT JSON) `+sql, args...).Scan(&raw); err != nil {
			return err
		}
		if err := json.Unmarshal(raw, &plan); err != nil {
			return err
		}
		return errRollback
	}); !errors.Is(err, errRollback) {
		t.Fatal(err)
	}
	var probes []string
	var top node
	var walk func(raw json.RawMessage, first bool)
	walk = func(raw json.RawMessage, first bool) {
		var n node
		if err := json.Unmarshal(raw, &n); err != nil {
			t.Fatal(err)
		}
		if first {
			top = n
		}
		if n.Relation == "messages" {
			p := n.Index
			if p == "" {
				p = n.NodeType
			}
			probes = append(probes, p)
		}
		var kids []json.RawMessage
		if len(n.Plans) > 0 {
			if err := json.Unmarshal(n.Plans, &kids); err != nil {
				t.Fatal(err)
			}
		}
		for _, k := range kids {
			walk(k, false)
		}
	}
	walk(plan[0].Plan, true)
	return probes, top.SharedHit + top.SharedRead, plan[0].ExecutionTime
}

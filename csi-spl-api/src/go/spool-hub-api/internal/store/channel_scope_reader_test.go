package store

import (
	"context"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// SPL-1832, rdb 0197 (owner HUM-10, t1 659e3927, poll 49b211d7, answer A):
// channel_scope on messages binds the hub's logins (spool_channel_scoped),
// never spool_search_reader, so the reader's word match is an Index Cond on
// messages_search again instead of a heap Filter over the whole tenant.
// Postgres only (SPOOL_TEST_PG_DSN, SPOOL_TEST_PG_RUNTIME_DSN). The name
// starts TestRLS, so hub-pg.tst.sh's RLS control counts it.

// readerPlanUsesWordIndex EXPLAINs the word match of spool_search_candidates
// as spool_search_reader in a savepoint of tx (the owner's transaction, so a
// plant made in it is seen) and reports whether an Index Cond holds
// search_tsv: whether the planner MAY read the word from messages_search.
// The word alone, without the body's tenant pin: on the small store DB a
// tenant-only index wins on cost even with no policy at all (measured, pg16),
// so the full body's plan would test the row count, not the policy.
// enable_seqscan off for the same reason.
func readerPlanUsesWordIndex(ctx context.Context, tx pgx.Tx, tenant string) (bool, string, error) {
	sp, err := tx.Begin(ctx)
	if err != nil {
		return false, "", err
	}
	defer sp.Rollback(ctx) //nolint:errcheck
	for _, q := range []string{
		`SET LOCAL enable_seqscan = off`,
		`SET LOCAL ROLE spool_search_reader`,
	} {
		if _, err := sp.Exec(ctx, q); err != nil {
			return false, "", err
		}
	}
	if _, err := sp.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tenant); err != nil {
		return false, "", err
	}
	rows, err := sp.Query(ctx, `EXPLAIN (COSTS OFF) SELECT m.msg_id, m.received_at FROM public.messages m
		WHERE m.search_tsv @@ to_tsquery('spool_search', 'archive')
		LIMIT 501`)
	if err != nil {
		return false, "", err
	}
	lines, err := pgx.CollectRows(rows, pgx.RowTo[string])
	if err != nil {
		return false, "", err
	}
	for _, l := range lines {
		if strings.Contains(l, "Index Cond:") && strings.Contains(l, "search_tsv") {
			return true, strings.Join(lines, "\n"), nil
		}
	}
	return false, strings.Join(lines, "\n"), nil
}

// TestRLSChannelScopeHubNotReader: (a) the policy's roles, (b) who it binds,
// (c) the reader's plan uses the word index. CONTROL (d): with the policy
// back on the 0169 shape (TO public, rolled back) the plan loses it.
func TestRLSChannelScopeHubNotReader(t *testing.T) {
	pg := rlsStore(t)
	_, rtRole := runtimeSession(t)
	ctx := context.Background()

	var bad []string
	err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT format('%s roles=%s', tablename, array_to_string(roles, ','))
			FROM pg_policies WHERE schemaname = current_schema() AND policyname = 'channel_scope'
			  AND roles <> CASE WHEN tablename = 'messages' THEN '{spool_channel_scoped}'::name[] ELSE '{public}'::name[] END
			ORDER BY 1`)
		if err != nil {
			return err
		}
		bad, err = pgx.CollectRows(rows, pgx.RowTo[string])
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, b := range bad {
		t.Errorf("(a) channel_scope on %s: want messages TO spool_channel_scoped, every other table TO public", b)
	}

	var owner string
	if err := pg.pool.QueryRow(ctx, `SELECT current_user`).Scan(&owner); err != nil {
		t.Fatal(err)
	}
	for role, want := range map[string]bool{rtRole: true, owner: true, "spool_search_reader": false} {
		var got bool
		if err := pg.pool.QueryRow(ctx, `SELECT pg_has_role($1, 'spool_channel_scoped', 'USAGE')`, role).Scan(&got); err != nil {
			t.Fatal(err)
		}
		if got != want {
			t.Errorf("(b) %s holds spool_channel_scoped by inheritance = %v, want %v", role, got, want)
		}
	}

	tenant := newTenant(t, pg)
	tx := ownerTx(t, pg)
	ok, plan, err := readerPlanUsesWordIndex(ctx, tx, tenant)
	if err != nil {
		t.Fatal(err)
	}
	if !ok {
		t.Errorf("(c) the reader's word match is no Index Cond:\n%s", plan)
	}

	if _, err := tx.Exec(ctx, `ALTER POLICY channel_scope ON messages TO public`); err != nil {
		t.Fatal(err)
	}
	ok, plan, err = readerPlanUsesWordIndex(ctx, tx, tenant)
	if err != nil {
		t.Fatal(err)
	}
	if ok {
		t.Fatalf("CONTROL (d): on the 0169 shape the word match is still an Index Cond: the check cannot tell\n%s", plan)
	}
}

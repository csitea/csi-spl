package store

import (
	"context"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestBudgetedScope: the budget is appended to the scope statement as an
// integer of milliseconds, and nothing is appended without one.
func TestBudgetedScope(t *testing.T) {
	ctx := context.Background()
	if got := budgeted(ctx, pgScopeTenant); got != pgScopeTenant {
		t.Fatalf("no budget: %q", got)
	}
	if got := budgeted(WithStatementTimeout(ctx, 0), pgScopeTenant); got != pgScopeTenant {
		t.Fatalf("budget 0: %q", got)
	}
	want := pgScopeTenant + ", set_config('statement_timeout', '2500', true)"
	if got := budgeted(WithStatementTimeout(ctx, 2500*time.Millisecond), pgScopeTenant); got != want {
		t.Fatalf("2.5 s: %q, want %q", got, want)
	}
	if got := budgeted(WithStatementTimeout(ctx, time.Microsecond), pgScopeTenant); !strings.HasSuffix(got, "'1', true)") {
		t.Fatalf("under 1 ms must round up to 1 ms, never 0 (= no limit): %q", got)
	}
}

// TestStatementBudget (Postgres, SPL-2866): a read under WithStatementTimeout
// is cancelled by Postgres at the budget (57014), on the one-statement batch
// path and in a transaction; the connection goes back to the pool whole (the
// same backend answers next); and the budget does not outlive its read: the
// next read on that connection runs under the role's own statement_timeout.
// CONTROL: the same sleep with no budget completes.
func TestStatementBudget(t *testing.T) {
	dsn := os.Getenv("SPOOL_TEST_PG_DSN")
	if dsn == "" {
		t.Skip("SPOOL_TEST_PG_DSN unset (run hub-pg.tst.sh)")
	}
	ctx := context.Background()
	pg, err := OpenPostgres(ctx, dsn+"&pool_max_conns=1")
	if err != nil {
		t.Fatal(err)
	}
	defer pg.Close()
	const tenant = "t-budget"
	read := func(ctx context.Context, sql string) (string, error) {
		var v string
		err := pg.queryRowTenant(ctx, tenant, sql, nil, &v)
		return v, err
	}
	setting := `SELECT current_setting('statement_timeout')`
	pid := `SELECT pg_backend_pid()::text`
	sleep := `SELECT pg_sleep(0.6)::text`
	roleDefault, err := read(ctx, setting)
	if err != nil {
		t.Fatal(err)
	}
	backend, _ := read(ctx, pid)

	if _, err := read(ctx, sleep); err != nil {
		t.Fatalf("CONTROL: no budget, the sleep must complete: %v", err)
	}
	bctx := WithStatementTimeout(ctx, 150*time.Millisecond)
	if v, err := read(bctx, setting); err != nil || v != "150ms" {
		t.Fatalf("under the budget statement_timeout = %q (%v), want 150ms", v, err)
	}
	start := time.Now()
	_, err = read(bctx, sleep)
	if !IsStatementTimeout(err) {
		t.Fatalf("batch path: a 600 ms statement under a 150 ms budget: %v, want SQLSTATE 57014", err)
	}
	if took := time.Since(start); took >= 600*time.Millisecond {
		t.Fatalf("batch path: cancelled after %s, not at the budget", took)
	}
	err = pg.inTenant(bctx, tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(bctx, sleep)
		return err
	})
	if !IsStatementTimeout(err) {
		t.Fatalf("transaction path: %v, want SQLSTATE 57014", err)
	}
	if v, _ := read(ctx, pid); v != backend {
		t.Fatalf("backend %s after the cancels, was %s: the connection was dropped, not returned", v, backend)
	}
	if v, err := read(ctx, setting); err != nil || v != roleDefault {
		t.Fatalf("after the budgeted reads statement_timeout = %q (%v), want the role's %q: the budget leaked", v, err, roleDefault)
	}
}

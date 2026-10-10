package store

import (
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Spec 121 T301 (sections 7, 8, 8.1): rdb 0171's usage_events,
// model_prices and token_budgets under row level security, the ledger's
// append-only trigger and the CHECKs that keep an unmetered turn from
// reading as zero. rls_failclosed_test.go's catalogue gate covers the
// policies' shape and TestCrossTenantEveryTable the unscoped writes
// (crosstenant_test.go seeds both tenant tables through seedUsage); this file
// proves what each scope reads and may write. Postgres only
// (SPOOL_TEST_PG_DSN).

// usageEventInsert writes one metered token row; $1 is tenant_id, $2 the
// turn id.
const usageEventInsert = `INSERT INTO usage_events (tenant_id, turn_id, kind, provider, model, units, unit_cost_micros, currency)
	VALUES ($1, $2, 'llm_tokens_in', 'mistral', 'mistral-small', 1200, 0.1, 'EUR')`

// tokenBudgetInsert writes the workspace budget of $1: a EUR 20 top-up.
const tokenBudgetInsert = `INSERT INTO token_budgets (tenant_id, topup_micros, topup_currency, topped_up_at)
	VALUES ($1, 20000000, 'EUR', now())`

// seedUsage writes one ledger row and the workspace budget of tenant under
// the tenant's own scope (the runtime path: RLS WITH CHECK admits them).
func seedUsage(ctx context.Context, pg *Postgres, tenant string) error {
	if _, err := pg.execTenant(ctx, tenant, usageEventInsert, tenant, uid("turn-")); err != nil {
		return err
	}
	_, err := pg.execTenant(ctx, tenant, tokenBudgetInsert, tenant)
	return err
}

// scopedTenantCount counts tb's rows of tenant in one fresh transaction under
// scope: "tenant:<id>", "operator", "empty" (app.tenant_id set empty) or "none".
// lift drops FORCE first (rolled back with the transaction): the CONTROL that
// the zeros are the policy's.
func scopedTenantCount(t *testing.T, pg *Postgres, scope, tb, tenant string, lift bool) int {
	t.Helper()
	ctx := context.Background()
	id := pgx.Identifier{tb}.Sanitize()
	n := -1
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) (err error) {
		if lift {
			if _, err = tx.Exec(ctx, `ALTER TABLE `+id+` NO FORCE ROW LEVEL SECURITY`); err != nil {
				return err
			}
		}
		switch {
		case scope == "operator":
			_, err = tx.Exec(ctx, pgScopeOperator)
		case scope == "empty":
			_, err = tx.Exec(ctx, pgScopeTenant, "")
		case strings.HasPrefix(scope, "tenant:"):
			_, err = tx.Exec(ctx, pgScopeTenant, strings.TrimPrefix(scope, "tenant:"))
		}
		if err != nil {
			return err
		}
		if err = tx.QueryRow(ctx, `SELECT count(*) FROM `+id+` WHERE tenant_id = $1`, tenant).Scan(&n); err != nil {
			return err
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) {
		t.Fatalf("%s %s: %v", tb, scope, err)
	}
	return n
}

// TestRLSUsageTablesScopes: for usage_events and token_budgets, workspace B
// reads none of A's rows, an empty scope and no scope read nothing
// (fail-closed), A and the operator read A's row. B cannot write an A row
// (WITH CHECK, 42501). CONTROL: with FORCE lifted (rolled back) the owner
// reads A's row under B's scope, so the zeros are the policy's. A tenant
// delete takes its rows with it, the append-only ledger included.
func TestRLSUsageTablesScopes(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	for _, tn := range []string{a, b} {
		if err := seedUsage(ctx, pg, tn); err != nil {
			t.Fatal(err)
		}
	}
	for _, tb := range []string{"usage_events", "token_budgets"} {
		for _, c := range []struct {
			scope string
			want  int
		}{{"tenant:" + b, 0}, {"empty", 0}, {"none", 0}, {"tenant:" + a, 1}, {"operator", 1}} {
			if got := scopedTenantCount(t, pg, c.scope, tb, a, false); got != c.want {
				t.Errorf("%s: scope %s reads %d of A's rows, want %d", tb, c.scope, got, c.want)
			}
		}
		if got := scopedTenantCount(t, pg, "tenant:"+b, tb, a, true); got != 1 {
			t.Errorf("CONTROL %s: without FORCE B's scope reads %d of A's rows, want 1", tb, got)
		}
	}
	if _, err := pg.execTenant(ctx, b, usageEventInsert, a, uid("turn-")); pgCode(err) != "42501" {
		t.Errorf("an A ledger row written under B's scope: %v (want WITH CHECK, 42501)", err)
	}
	if _, err := pg.execTenant(ctx, b, `INSERT INTO token_budgets (tenant_id, tokens_per_day) VALUES ($1, 10)`, a); pgCode(err) != "42501" {
		t.Errorf("an A budget written under B's scope: %v (want WITH CHECK, 42501)", err)
	}
	tag, err := pg.execTenant(ctx, b, `UPDATE token_budgets SET tokens_per_day = 0 WHERE tenant_id = $1`, a)
	if err != nil || tag.RowsAffected() != 0 {
		t.Errorf("B's scope reached %d of A's budgets (%v)", tag.RowsAffected(), err)
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = $1`, a)
		return err
	}); err != nil {
		t.Fatalf("tenant delete with a ledger row: %v (the cascade must pass the append-only trigger)", err)
	}
	for _, tb := range []string{"usage_events", "token_budgets"} {
		if got := scopedTenantCount(t, pg, "operator", tb, a, false); got != 0 {
			t.Errorf("after the tenant delete A holds %d %s rows", got, tb)
		}
	}
}

// TestUsageEventsAppendOnly: an UPDATE and a DELETE of a ledger row are
// refused in the workspace's own scope and in the operator scope.
// CONTROL: with the trigger dropped (rolled back) the same UPDATE passes, so
// the refusal is the trigger's and not RLS's.
func TestUsageEventsAppendOnly(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := newTenant(t, pg)
	if err := seedUsage(ctx, pg, a); err != nil {
		t.Fatal(err)
	}
	for _, w := range []string{`UPDATE usage_events SET units = 0 WHERE tenant_id = $1`, `DELETE FROM usage_events WHERE tenant_id = $1`} {
		if _, err := pg.execTenant(ctx, a, w, a); err == nil || !strings.Contains(err.Error(), "append-only") {
			t.Errorf("workspace scope: %s: %v, want the append-only refusal", w, err)
		}
		if err := pg.asOperator(ctx, func(tx pgx.Tx) error { _, err := tx.Exec(ctx, w, a); return err }); err == nil || !strings.Contains(err.Error(), "append-only") {
			t.Errorf("operator scope: %s: %v, want the append-only refusal", w, err)
		}
	}
	var n int64
	err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DROP TRIGGER append_only ON usage_events`); err != nil {
			return err
		}
		tag, err := tx.Exec(ctx, `UPDATE usage_events SET units = 0 WHERE tenant_id = $1`, a)
		n = tag.RowsAffected()
		if err != nil {
			return err
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) || n != 1 {
		t.Fatalf("CONTROL: without the trigger the UPDATE reached %d rows (%v), want 1", n, err)
	}
	if got := scopedTenantCount(t, pg, "operator", "usage_events", a, false); got != 1 {
		t.Fatalf("the trigger is back after the rollback? A holds %d rows", got)
	}
}

// TestUsageEventsShape: an unmetered turn carries no units, cost or currency
// and names its turn, a metered row carries all three, a token row names
// its provider and model (23514 otherwise); a re-sent report of the same
// (turn, kind) is 23505. An unmetered row never sums as tokens: SUM(units)
// over it alone is NULL, not 0.
func TestUsageEventsShape(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := newTenant(t, pg)
	turn := uid("turn-")
	ins := func(sql string, args ...any) error {
		_, err := pg.execTenant(ctx, a, sql, append([]any{a}, args...)...)
		return err
	}
	for _, c := range []struct {
		name, sql, code string
	}{
		{"unmetered", `INSERT INTO usage_events (tenant_id, turn_id, kind) VALUES ($1, '` + turn + `', 'unmetered')`, ""},
		{"unmetered with units", `INSERT INTO usage_events (tenant_id, turn_id, kind, units) VALUES ($1, 'u2', 'unmetered', 0)`, "23514"},
		{"unmetered without a turn", `INSERT INTO usage_events (tenant_id, kind) VALUES ($1, 'unmetered')`, "23514"},
		{"metered without a cost", `INSERT INTO usage_events (tenant_id, kind, provider, model, units, currency)
			VALUES ($1, 'llm_tokens_out', 'mistral', 'm', 5, 'EUR')`, "23514"},
		{"tokens without a model", `INSERT INTO usage_events (tenant_id, kind, provider, units, unit_cost_micros, currency)
			VALUES ($1, 'llm_tokens_out', 'mistral', 5, 1, 'EUR')`, "23514"},
		{"seconds without a model", `INSERT INTO usage_events (tenant_id, kind, units, unit_cost_micros, currency)
			VALUES ($1, 'agent_seconds', 60, 2, 'EUR')`, ""},
		{"unknown kind", `INSERT INTO usage_events (tenant_id, kind, units, unit_cost_micros, currency)
			VALUES ($1, 'guess', 1, 1, 'EUR')`, "23514"},
	} {
		if err := ins(c.sql); pgCode(err) != c.code && !(c.code == "" && err == nil) {
			t.Errorf("%s: %v, want %q", c.name, err, c.code)
		}
	}
	if err := ins(usageEventInsert, turn+"-x"); err != nil {
		t.Fatal(err)
	}
	if err := ins(usageEventInsert, turn+"-x"); pgCode(err) != "23505" {
		t.Errorf("a re-sent report of the same turn and kind: %v, want 23505", err)
	}
	var sum *string
	if err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT sum(units)::text FROM usage_events WHERE tenant_id = $1 AND turn_id = $2`, a, turn).Scan(&sum)
	}); err != nil || sum != nil {
		t.Errorf("the unmetered turn sums to %v (%v), want NULL", sum, err)
	}
}

// TestRLSModelPrices: a workspace scope reads every price but cannot write
// one (42501); no scope and an empty scope read none; the operator writes a
// price change as a new row, and the price in force is the latest
// valid_from <= now.
func TestRLSModelPrices(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := newTenant(t, pg)
	model := uid("m-")
	ins := `INSERT INTO model_prices (provider, model, kind, micros_per_million, currency, valid_from)
		VALUES ('mistral', $1, 'llm_tokens_in', $2, 'EUR', $3::timestamptz)`
	for _, p := range []struct {
		micros int64
		from   string
	}{{100000, "2026-01-01"}, {90000, "2026-09-01"}, {80000, "2099-01-01"}} {
		if err := pg.asOperator(ctx, func(tx pgx.Tx) error { _, err := tx.Exec(ctx, ins, model, p.micros, p.from); return err }); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := pg.execTenant(ctx, a, ins, model, 1, "2026-10-01"); pgCode(err) != "42501" {
		t.Errorf("a workspace scope wrote a price: %v (want 42501)", err)
	}
	read := func(scope string) (n int, now int64) {
		if err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) (err error) {
			switch scope {
			case "empty":
				_, err = tx.Exec(ctx, pgScopeTenant, "")
			case "tenant":
				_, err = tx.Exec(ctx, pgScopeTenant, a)
			}
			if err != nil {
				return err
			}
			if err = tx.QueryRow(ctx, `SELECT count(*) FROM model_prices WHERE model = $1`, model).Scan(&n); err != nil || n == 0 {
				return err
			}
			return tx.QueryRow(ctx, `SELECT micros_per_million FROM model_prices WHERE model = $1 AND valid_from <= now()
				ORDER BY valid_from DESC LIMIT 1`, model).Scan(&now)
		}); err != nil {
			t.Fatalf("%s: %v", scope, err)
		}
		return n, now
	}
	if n, now := read("tenant"); n != 3 || now != 90000 {
		t.Errorf("a workspace scope reads %d prices, in force %d; want 3, 90000", n, now)
	}
	for _, s := range []string{"empty", "none"} {
		if n, _ := read(s); n != 0 {
			t.Errorf("scope %s reads %d prices, want 0", s, n)
		}
	}
}

// TestTokenBudgetsShape: a new budget is a hard stop with auto top-up OFF
// (spec 8.1: never nudge spend); auto top-up needs its cap, a budget scopes
// a channel or a visitor but not both, a budget needs a limit and a top-up
// needs its currency and time (23514); one budget per scope, the workspace
// one included (NULLS NOT DISTINCT, 23505).
func TestTokenBudgetsShape(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := newTenant(t, pg)
	if err := seedUsage(ctx, pg, a); err != nil {
		t.Fatal(err)
	}
	var hard, auto bool
	if err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT hard_stop, auto_topup FROM token_budgets WHERE tenant_id = $1`, a).Scan(&hard, &auto)
	}); err != nil || !hard || auto {
		t.Errorf("new budget: hard_stop %v auto_topup %v (%v); want true, false", hard, auto, err)
	}
	for _, c := range []struct {
		name, sql, code string
	}{
		{"auto top-up without a cap", `INSERT INTO token_budgets (tenant_id, channel_id, tokens_per_day, auto_topup) VALUES ($1, 'c1', 1, true)`, "23514"},
		{"channel and visitor", `INSERT INTO token_budgets (tenant_id, channel_id, visitor_id, tokens_per_day) VALUES ($1, 'c1', gen_random_uuid(), 1)`, "23514"},
		{"no limit", `INSERT INTO token_budgets (tenant_id, channel_id) VALUES ($1, 'c1')`, "23514"},
		{"top-up without currency", `INSERT INTO token_budgets (tenant_id, channel_id, topup_micros, topped_up_at) VALUES ($1, 'c1', 5, now())`, "23514"},
		{"a second workspace budget", `INSERT INTO token_budgets (tenant_id, tokens_per_day) VALUES ($1, 1)`, "23505"},
		{"a channel budget", `INSERT INTO token_budgets (tenant_id, channel_id, tokens_per_month) VALUES ($1, 'c1', 1000)`, ""},
		{"the same channel again", `INSERT INTO token_budgets (tenant_id, channel_id, tokens_per_day) VALUES ($1, 'c1', 1)`, "23505"},
	} {
		if _, err := pg.execTenant(ctx, a, c.sql, a); pgCode(err) != c.code && !(c.code == "" && err == nil) {
			t.Errorf("%s: %v, want %q", c.name, err, c.code)
		}
	}
}

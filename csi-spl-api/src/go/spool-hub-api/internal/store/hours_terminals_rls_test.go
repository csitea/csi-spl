package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Spec 107 v2 T065 (FR-20, FR-25, FR-37): rdb 0222's terminal and PIN
// tables under row level security, their CHECKs, and hours.rates pinned to
// time_accountant. rls_failclosed_test.go's catalogue gate covers the
// policies' shape and TestCrossTenantEveryTable the unscoped writes
// (crosstenant_test.go seeds one row of each through seedHoursTerminals);
// this file proves what each scope reads and may write. Postgres only
// (SPOOL_TEST_PG_DSN).

// hoursTerminalTables are rdb 0222's tables.
var hoursTerminalTables = []string{"hours_terminals", "hours_member_pins"}

// seedHoursTerminals writes one terminal and member's PIN and badge in
// tenant, under the tenant's own scope (the runtime path: RLS WITH CHECK
// admits it). The hashes are sha256 of tenant-unique text, stand-ins for
// T031's peppered ones.
func seedHoursTerminals(ctx context.Context, pg *Postgres, tenant, member string) error {
	return pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		for _, q := range []struct {
			sql  string
			args []any
		}{
			{`INSERT INTO hours_terminals (tenant_id, name, token_hash, created_by)
				VALUES ($1, 'Site gate', sha256(convert_to('token:' || $1, 'UTF8')), 'HUM-9')`, []any{tenant}},
			{`INSERT INTO hours_member_pins (tenant_id, member_id, pin_hash, badge_hash, updated_by)
				VALUES ($1, $2, sha256(convert_to('pin:' || $1 || $2, 'UTF8')), sha256(convert_to('badge:' || $1 || $2, 'UTF8')), 'HUM-9')`,
				[]any{tenant, member}},
		} {
			if _, err := tx.Exec(ctx, q.sql, q.args...); err != nil {
				return fmt.Errorf("%w\n%s", err, q.sql)
			}
		}
		return nil
	})
}

// hoursTerminalCounts reads t1's rows of each table in one fresh
// transaction under scope: "tenant:<id>", "operator", "empty" or "none".
func hoursTerminalCounts(t *testing.T, pg *Postgres, scope, t1 string) string {
	t.Helper()
	ctx := context.Background()
	out := ""
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) (err error) {
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
		for _, tb := range hoursTerminalTables {
			var n int
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM `+tb+` WHERE tenant_id = $1`, t1).Scan(&n); err != nil {
				return err
			}
			out += fmt.Sprintf("%s=%d ", tb, n)
		}
		return nil
	})
	if err != nil {
		t.Fatalf("%s: %v", scope, err)
	}
	return out
}

// TestRLSHoursTerminalsScopes: t2's scope, an empty scope and no scope read
// none of t1's terminal or PIN rows (fail-closed); t1's scope and the
// operator read them; a t1 row written under t2's scope fails WITH CHECK
// (42501), and an UPDATE or DELETE of t1's rows under t2's scope reaches
// none. A tenant delete cascades both tables. CONTROL: with FORCE lifted
// (rolled back) the owner reads t1's PIN row under t2's scope, so the zeros
// above are the policy's.
func TestRLSHoursTerminalsScopes(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	t1, t2 := newTenant(t, pg), newTenant(t, pg)
	if err := seedHoursTerminals(ctx, pg, t1, "HUM-1"); err != nil {
		t.Fatal(err)
	}
	all, none := "hours_terminals=1 hours_member_pins=1 ", "hours_terminals=0 hours_member_pins=0 "
	for _, c := range []struct{ scope, want string }{
		{"tenant:" + t2, none}, {"empty", none}, {"none", none}, {"tenant:" + t1, all}, {"operator", all},
	} {
		if got := hoursTerminalCounts(t, pg, c.scope, t1); got != c.want {
			t.Errorf("scope %s reads %s, want %s", c.scope, got, c.want)
		}
	}
	if err := seedHoursTerminals(ctx, pg, t2, "HUM-1"); err != nil { // t2's own rows: admitted
		t.Fatalf("t2's own rows: %v", err)
	}
	for _, w := range []string{
		`INSERT INTO hours_terminals (tenant_id, name, token_hash, created_by)
			VALUES ($1, 'x', sha256(convert_to('other-token', 'UTF8')), 'HUM-9')`,
		`INSERT INTO hours_member_pins (tenant_id, member_id, pin_hash, updated_by)
			VALUES ($1, 'HUM-2', sha256(convert_to('other-pin', 'UTF8')), 'HUM-9')`,
	} {
		if _, err := pg.execTenant(ctx, t2, w, t1); pgCode(err) != "42501" {
			t.Errorf("a t1 row written under t2's scope: %v (want WITH CHECK, 42501)\n%s", err, w)
		}
	}
	for _, w := range []string{
		`UPDATE hours_terminals SET revoked_at = now() WHERE tenant_id = $1`,
		`UPDATE hours_member_pins SET failed_count = 0, locked_until = NULL WHERE tenant_id = $1`,
		`DELETE FROM hours_terminals WHERE tenant_id = $1`,
		`DELETE FROM hours_member_pins WHERE tenant_id = $1`,
	} {
		tag, err := pg.execTenant(ctx, t2, w, t1)
		if err != nil || tag.RowsAffected() != 0 {
			t.Errorf("t2's scope reached %d of t1's rows: %v\n%s", tag.RowsAffected(), err, w)
		}
	}
	if got := hoursTerminalCounts(t, pg, "operator", t1); got != all {
		t.Fatalf("after t2's writes t1 holds %s, want %s", got, all)
	}
	hoursTerminalsLiftControl(t, pg, t1, t2)
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = $1`, t1)
		return err
	}); err != nil {
		t.Fatalf("a tenant delete must cascade the terminal tables: %v", err)
	}
	if got := hoursTerminalCounts(t, pg, "operator", t1); got != none {
		t.Fatalf("after the tenant delete: %s", got)
	}
	if got := hoursTerminalCounts(t, pg, "operator", t2); got != all {
		t.Fatalf("t1's delete touched t2: %s", got)
	}
}

// hoursTerminalsLiftControl lifts FORCE on hours_member_pins in a
// rolled-back transaction: the owner then reads t1's PIN row under t2's scope.
func hoursTerminalsLiftControl(t *testing.T, pg *Postgres, t1, t2 string) {
	t.Helper()
	ctx := context.Background()
	var n int
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
		for _, q := range []string{`ALTER TABLE hours_member_pins NO FORCE ROW LEVEL SECURITY`, `SELECT set_config('app.tenant_id', '` + t2 + `', true)`} {
			if _, err := tx.Exec(ctx, q); err != nil {
				return err
			}
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM hours_member_pins WHERE tenant_id = $1`, t1).Scan(&n); err != nil {
			return err
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) {
		t.Fatalf("control: %v", err)
	}
	if n != 1 {
		t.Fatalf("CONTROL: without FORCE the owner read %d of t1's PIN rows under t2's scope, want 1", n)
	}
}

// TestHoursTerminalsChecks (FR-25): a terminal needs a name and a token
// hash of 32..64 bytes, unique across the hub; a revoke cannot predate the
// registration. A PIN row needs a PIN hash; a badge is unique per workspace
// (the same badge hash in another workspace is admitted); the failed count
// is never negative. Each refused write is a 23514 / 23505 / 23502; the
// CONTROL is the admitted rows of seedHoursTerminals.
func TestHoursTerminalsChecks(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	t1, t2 := newTenant(t, pg), newTenant(t, pg)
	if err := seedHoursTerminals(ctx, pg, t1, "HUM-1"); err != nil {
		t.Fatalf("CONTROL: the seed rows: %v", err)
	}
	for _, c := range []struct{ code, sql string }{
		{"23514", `INSERT INTO hours_terminals (tenant_id, name, token_hash, created_by) VALUES ($1, '  ', sha256('\x01'::bytea), 'HUM-9')`},
		{"23514", `INSERT INTO hours_terminals (tenant_id, name, token_hash, created_by) VALUES ($1, 'Gate', '\x0102'::bytea, 'HUM-9')`},
		{"23505", `INSERT INTO hours_terminals (tenant_id, name, token_hash, created_by) VALUES ($1, 'Gate 2', sha256(convert_to('token:' || $1, 'UTF8')), 'HUM-9')`},
		{"23514", `INSERT INTO hours_terminals (tenant_id, name, token_hash, created_by, created_at, revoked_at)
			VALUES ($1, 'Gate', sha256('\x02'::bytea), 'HUM-9', now(), now() - interval '1 day')`},
		{"23502", `INSERT INTO hours_member_pins (tenant_id, member_id, updated_by) VALUES ($1, 'HUM-2', 'HUM-9')`},
		{"23505", `INSERT INTO hours_member_pins (tenant_id, member_id, pin_hash, badge_hash, updated_by)
			VALUES ($1, 'HUM-2', sha256('\x03'::bytea), sha256(convert_to('badge:' || $1 || 'HUM-1', 'UTF8')), 'HUM-9')`},
		{"23514", `INSERT INTO hours_member_pins (tenant_id, member_id, pin_hash, failed_count, updated_by) VALUES ($1, 'HUM-2', sha256('\x04'::bytea), -1, 'HUM-9')`},
	} {
		if _, err := pg.execTenant(ctx, t1, c.sql, t1); pgCode(err) != c.code {
			t.Errorf("%v, want %s\n%s", err, c.code, c.sql)
		}
	}
	// t1's badge bytes in t2 are admitted: a badge is unique per workspace only.
	if _, err := pg.execTenant(ctx, t2, `INSERT INTO hours_member_pins (tenant_id, member_id, pin_hash, badge_hash, updated_by)
		VALUES ($1, 'HUM-1', sha256('\x05'::bytea), sha256(convert_to('badge:' || $2 || 'HUM-1', 'UTF8')), 'HUM-9')`, t2, t1); err != nil {
		t.Errorf("t1's badge bytes in t2: %v, want admitted", err)
	}
}

// TestHoursRatesPinnedToTimeAccountant (FR-20): the seed gives
// time_accountant exactly hours.read and hours.rates and no other role
// hours.rates; a grant of hours.rates to another role is refused (23514)
// for the operator on a system role and for a workspace on its own custom
// role. CONTROL: the same workspace role is granted hours.read.
func TestHoursRatesPinnedToTimeAccountant(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	var ta, holders []string
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT array_agg(permission_id ORDER BY permission_id) FROM rbac_role_permissions
			WHERE role_id = 'time_accountant'`).Scan(&ta); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `SELECT array_agg(role_id ORDER BY role_id) FROM rbac_role_permissions
			WHERE permission_id = 'hours.rates'`).Scan(&holders)
	}); err != nil {
		t.Fatal(err)
	}
	if strings.Join(ta, ",") != "hours.rates,hours.read" || strings.Join(holders, ",") != "time_accountant" {
		t.Fatalf("time_accountant holds %v, hours.rates is held by %v", ta, holders)
	}
	err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES ('biz_owner', 'hours.rates')`)
		return err
	})
	if pgCode(err) != "23514" {
		t.Errorf("the operator granted biz_owner hours.rates: %v, want 23514", err)
	}
	tn := newTenant(t, pg)
	role := "acct_" + strings.ReplaceAll(uuid4()[:8], "-", "")
	if _, err := pg.execTenant(ctx, tn, `INSERT INTO rbac_roles (role_id, tenant_id, description) VALUES ($1, $2, 'custom')`, role, tn); err != nil {
		t.Fatalf("a workspace role: %v", err)
	}
	if _, err := pg.execTenant(ctx, tn, `INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES ($1, 'hours.rates')`, role); pgCode(err) != "23514" {
		t.Errorf("a workspace granted its own role hours.rates: %v, want 23514", err)
	}
	if _, err := pg.execTenant(ctx, tn, `INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES ($1, 'hours.read')`, role); err != nil {
		t.Errorf("CONTROL: a workspace grants its own role hours.read: %v", err)
	}
}

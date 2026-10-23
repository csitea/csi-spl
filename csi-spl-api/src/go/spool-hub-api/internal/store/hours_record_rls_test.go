package store

import (
	"context"
	"errors"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 107 v2 T022 (FR-32, FR-33, FR-35, FR-40): rdb 0215's record tables
// under row level security, their CHECKs, and the append-only change log
// with its one narrow prune exit. rls_failclosed_test.go's catalogue gate
// covers the policies' shape and TestCrossTenantEveryTable the unscoped
// writes (crosstenant_test.go seeds one row of each); this file proves what
// each scope reads and may write. Postgres only (SPOOL_TEST_PG_DSN).

// hoursRecordTables are rdb 0215's tables.
var hoursRecordTables = []string{"hours_days", "hours_changes", "hours_adjustments", "hours_ops"}

// seedHoursRecord writes one row of each record table for member in tenant,
// under the tenant's own scope (the runtime path: RLS WITH CHECK admits
// it). The change row is stamped at, so a prune can be aimed at it.
func seedHoursRecord(ctx context.Context, pg *Postgres, tenant, member string, at time.Time) error {
	return pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		day := at.UTC().Format("2006-01-02")
		for _, q := range []struct {
			sql  string
			args []any
		}{
			{`INSERT INTO hours_days (tenant_id, member_id, day, start_at, end_at, break_minutes, standard_minutes, sources, written_by)
				VALUES ($1, $2, $3::date, $3::date + time '08:00', $3::date + time '16:30', 30, 480,
				        '{"start_at": "plan", "end_at": "standard", "break_minutes": "standard"}', 'sweep')`,
				[]any{tenant, member, day}},
			{`INSERT INTO hours_changes (tenant_id, actor, actor_kind, at, member_id, object, key, before, after, reason)
				VALUES ($1, $2, 'member', $3, $2, 'entry', $4, '{"minutes": 15}', '{"minutes": 30}', 'forgot the meeting')`,
				[]any{tenant, member, at, day + "/ws/work"}},
			{`INSERT INTO hours_adjustments (tenant_id, member_id, period_start, corrects_day, kind, target, minutes, reason, created_by)
				VALUES ($1, $2, $3::date + 7, $3::date, 'work', 'ws', -30, 'double booked', 'HUM-9')`,
				[]any{tenant, member, day}},
			{`INSERT INTO hours_ops (tenant_id, member_id, op_id, at) VALUES ($1, $2, $3, $4)`,
				[]any{tenant, member, "op-" + uuid4(), at}},
		} {
			if _, err := tx.Exec(ctx, q.sql, q.args...); err != nil {
				return fmt.Errorf("%w\n%s", err, q.sql)
			}
		}
		return nil
	})
}

// hoursRecordCounts reads t1's rows of each record table in one fresh
// transaction under scope: "tenant:<id>", "operator", "empty" or "none".
func hoursRecordCounts(t *testing.T, pg *Postgres, scope, t1 string) string {
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
		for _, tb := range hoursRecordTables {
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

// TestRLSHoursRecordScopes: t2's scope, an empty scope and no scope read
// none of t1's record rows (fail-closed); t1's scope and the operator read
// all of them; a t1 row written under t2's scope fails WITH CHECK (42501),
// and an UPDATE or DELETE of t1's rows under t2's scope reaches none (the
// change log's trigger never fires: RLS hides the rows first). A tenant
// delete cascades every table, the append-only change log included.
// CONTROL: with FORCE lifted (rolled back) the owner reads t1's day record
// under t2's scope, so the zeros above are the policy's.
func TestRLSHoursRecordScopes(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	t1, t2 := newTenant(t, pg), newTenant(t, pg)
	now := time.Now().UTC()
	if err := seedHoursRecord(ctx, pg, t1, "HUM-1", now); err != nil {
		t.Fatal(err)
	}
	all, none := "hours_days=1 hours_changes=1 hours_adjustments=1 hours_ops=1 ",
		"hours_days=0 hours_changes=0 hours_adjustments=0 hours_ops=0 "
	for _, c := range []struct{ scope, want string }{
		{"tenant:" + t2, none}, {"empty", none}, {"none", none}, {"tenant:" + t1, all}, {"operator", all},
	} {
		if got := hoursRecordCounts(t, pg, c.scope, t1); got != c.want {
			t.Errorf("scope %s reads %s, want %s", c.scope, got, c.want)
		}
	}
	if err := seedHoursRecord(ctx, pg, t2, "HUM-1", now); err != nil { // t2's own rows: admitted
		t.Fatalf("t2's own rows: %v", err)
	}
	for _, w := range []string{
		`INSERT INTO hours_days (tenant_id, member_id, day, standard_minutes, written_by) VALUES ($1, 'HUM-2', current_date, 480, 'sweep')`,
		`INSERT INTO hours_changes (tenant_id, actor, actor_kind, object, key) VALUES ($1, 'sweep', 'sweep', 'period', 'HUM-2')`,
		`INSERT INTO hours_adjustments (tenant_id, member_id, period_start, corrects_day, kind, target, minutes, reason, created_by)
			VALUES ($1, 'HUM-2', current_date, current_date - 9, 'work', 'ws', 15, 'late entry', 'HUM-9')`,
		`INSERT INTO hours_ops (tenant_id, member_id, op_id) VALUES ($1, 'HUM-2', 'op-x')`,
	} {
		if _, err := pg.execTenant(ctx, t2, w, t1); pgCode(err) != "42501" {
			t.Errorf("a t1 row written under t2's scope: %v (want WITH CHECK, 42501)\n%s", err, w)
		}
	}
	for _, tb := range hoursRecordTables {
		tag, err := pg.execTenant(ctx, t2, `UPDATE `+tb+` SET member_id = 'HUM-X' WHERE tenant_id = $1`, t1)
		if err != nil || tag.RowsAffected() != 0 {
			t.Errorf("t2's scope updated %d %s rows of t1: %v", tag.RowsAffected(), tb, err)
		}
		tag, err = pg.execTenant(ctx, t2, `DELETE FROM `+tb+` WHERE tenant_id = $1`, t1)
		if err != nil || tag.RowsAffected() != 0 {
			t.Errorf("t2's scope deleted %d %s rows of t1: %v", tag.RowsAffected(), tb, err)
		}
	}
	if got := hoursRecordCounts(t, pg, "operator", t1); got != all {
		t.Fatalf("after t2's writes t1 holds %s, want %s", got, all)
	}
	hoursRecordLiftControl(t, pg, t1, t2)
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = $1`, t1)
		return err
	}); err != nil {
		t.Fatalf("a tenant delete must cascade the record tables, the change log included: %v", err)
	}
	if got := hoursRecordCounts(t, pg, "operator", t1); got != none {
		t.Fatalf("after the tenant delete: %s", got)
	}
	if got := hoursRecordCounts(t, pg, "operator", t2); got != all {
		t.Fatalf("t1's delete touched t2: %s", got)
	}
}

// hoursRecordLiftControl lifts FORCE on hours_days in a rolled-back
// transaction: the owner then reads t1's day under t2's scope.
func hoursRecordLiftControl(t *testing.T, pg *Postgres, t1, t2 string) {
	t.Helper()
	ctx := context.Background()
	var n int
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
		for _, q := range []string{`ALTER TABLE hours_days NO FORCE ROW LEVEL SECURITY`, `SELECT set_config('app.tenant_id', '` + t2 + `', true)`} {
			if _, err := tx.Exec(ctx, q); err != nil {
				return err
			}
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM hours_days WHERE tenant_id = $1`, t1).Scan(&n); err != nil {
			return err
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) {
		t.Fatalf("control: %v", err)
	}
	if n != 1 {
		t.Fatalf("CONTROL: without FORCE the owner read %d of t1's days under t2's scope, want 1", n)
	}
}

// hoursChangesLeft counts tenant's change-log rows as the operator.
func hoursChangesLeft(t *testing.T, pg *Postgres, tenant string) int {
	t.Helper()
	var n int
	if err := pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		return tx.QueryRow(context.Background(), `SELECT count(*) FROM hours_changes WHERE tenant_id = $1`, tenant).Scan(&n)
	}); err != nil {
		t.Fatal(err)
	}
	return n
}

// TestHoursChangesAppendOnly (FR-33): as the hub's runtime role an UPDATE
// and a DELETE on hours_changes fail "append-only", in the workspace scope
// and in the operator scope; setting any flag first (app.rls_scope, a
// made-up app.hours_prune) changes nothing, and the owner is refused too.
// The one deleter is hours_changes_prune: as the runtime role in t1's scope
// it deletes t1's rows older than the cut and keeps t1's newer row and
// every t2 row; with no scope it deletes none. The runtime role cannot SET
// ROLE to the pruner, PUBLIC has no EXECUTE on the prune, and the pruner
// holds SELECT and DELETE on hours_changes and nothing else.
func TestHoursChangesAppendOnly(t *testing.T) {
	pg := rlsStore(t)
	rt, role := runtimeStore(t)
	ctx := context.Background()
	t1, t2 := newTenant(t, pg), newTenant(t, pg)
	now := time.Now().UTC()
	old := now.Add(-400 * 24 * time.Hour)
	for _, s := range []struct {
		tenant string
		at     time.Time
	}{{t1, old}, {t1, now}, {t2, old}} {
		if err := seedHoursRecord(ctx, rt, s.tenant, "HUM-1", s.at); err != nil {
			t.Fatalf("the runtime role appends a change: %v", err)
		}
	}
	refused := func(name string, db *Postgres, setup []string, w string) {
		t.Helper()
		err := pgx.BeginFunc(ctx, db.pool, func(tx pgx.Tx) error {
			for _, q := range setup {
				if _, err := tx.Exec(ctx, q); err != nil {
					return err
				}
			}
			_, err := tx.Exec(ctx, w)
			return err
		})
		if err == nil || !strings.Contains(err.Error(), "append-only") {
			t.Errorf("%s: %s: %v, want the append-only refusal", name, w, err)
		}
	}
	inT1 := `SELECT set_config('app.tenant_id', '` + t1 + `', true)`
	for _, w := range []string{
		`UPDATE hours_changes SET reason = 'rewritten'`,
		`DELETE FROM hours_changes`,
	} {
		refused(role+" in t1's scope", rt, []string{inT1}, w)
		refused(role+" as the operator", rt, []string{pgScopeOperator}, w)
		refused(role+" with every flag set", rt, []string{inT1, pgScopeOperator,
			`SELECT set_config('app.hours_prune', 'on', true)`, `SELECT set_config('app.rls_scope', 'pruner', true)`}, w)
		refused("the owner as the operator", pg, []string{pgScopeOperator}, w)
	}
	if n := hoursChangesLeft(t, pg, t1); n != 2 {
		t.Fatalf("t1 holds %d change rows after the refused writes, want 2", n)
	}

	prune := func(setup string) (int, error) {
		var n int
		err := pgx.BeginFunc(ctx, rt.pool, func(tx pgx.Tx) error {
			if setup != "" {
				if _, err := tx.Exec(ctx, setup); err != nil {
					return err
				}
			}
			return tx.QueryRow(ctx, `SELECT hours_changes_prune($1)`, now.Add(-365*24*time.Hour)).Scan(&n)
		})
		return n, err
	}
	if n, err := prune(""); err != nil || n != 0 {
		t.Errorf("the prune with no scope deleted %d row(s) (%v), want 0", n, err)
	}
	if n, err := prune(inT1); err != nil || n != 1 {
		t.Fatalf("the prune in t1's scope as %s deleted %d row(s) (%v), want t1's one old row", role, n, err)
	}
	if n1, n2 := hoursChangesLeft(t, pg, t1), hoursChangesLeft(t, pg, t2); n1 != 1 || n2 != 1 {
		t.Fatalf("after the prune t1 holds %d, t2 %d change rows; want t1's newer row and t2's old one", n1, n2)
	}

	err := pgx.BeginFunc(ctx, rt.pool, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `SET LOCAL ROLE spool_hours_pruner`)
		return err
	})
	if pgCode(err) != "42501" {
		t.Errorf("%s took SET ROLE spool_hours_pruner: %v, want 42501", role, err)
	}
	var facts string
	if err := pg.pool.QueryRow(ctx, `SELECT
			has_function_privilege('public', 'hours_changes_prune(timestamptz)', 'EXECUTE') || ' ' ||
			p.prosecdef || ' ' || pg_get_userbyid(p.proowner) || ' ' ||
			(SELECT r.rolcanlogin || ' ' || r.rolbypassrls FROM pg_roles r WHERE r.rolname = 'spool_hours_pruner') || ' ' ||
			(SELECT string_agg(table_name || ':' || privilege_type, ',' ORDER BY table_name, privilege_type)
			   FROM information_schema.role_table_grants WHERE grantee = 'spool_hours_pruner')
		FROM pg_proc p WHERE p.oid = 'hours_changes_prune(timestamptz)'::regprocedure`).Scan(&facts); err != nil {
		t.Fatal(err)
	}
	if want := "false true spool_hours_pruner false false hours_changes:DELETE,hours_changes:SELECT"; facts != want {
		t.Errorf("the prune door: %q, want %q (public execute, definer, owner, login, bypassrls, the pruner's grants)", facts, want)
	}
}

// TestHoursRecordChecks: the CHECKs of the record tables refuse what they
// must (23514) and admit the edge that is valid; each insert runs in the
// tenant's scope.
func TestHoursRecordChecks(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := newTenant(t, pg)
	day := func(d, start, end string, brk int, noBreak bool, sources string) string {
		ts := func(v string) string {
			if v == "" {
				return "NULL"
			}
			return "'" + d + "T" + v + "Z'"
		}
		return fmt.Sprintf(`INSERT INTO hours_days (tenant_id, member_id, day, start_at, end_at, break_minutes, standard_minutes, no_break, sources, written_by)
			VALUES ($1, 'HUM-1', '%s', %s, %s, %d, 480, %v, '%s', 'HUM-1')`, d, ts(start), ts(end), brk, noBreak, sources)
	}
	change := func(actor, kind, object, reason string) string {
		return fmt.Sprintf(`INSERT INTO hours_changes (tenant_id, actor, actor_kind, member_id, object, key, reason)
			VALUES ($1, '%s', '%s', 'HUM-1', '%s', '2026-10-06/ws/work', %s)`, actor, kind, object, reason)
	}
	adj := func(period, corrects, kind, target string, minutes int, reason string) string {
		return fmt.Sprintf(`INSERT INTO hours_adjustments (tenant_id, member_id, period_start, corrects_day, kind, target, minutes, reason, created_by)
			VALUES ($1, 'HUM-1', '%s', '%s', '%s', '%s', %d, '%s', 'HUM-9')`, period, corrects, kind, target, minutes, reason)
	}
	for _, c := range []struct {
		name, sql string
		ok        bool
	}{
		{"day full", day("2026-10-01", "08:00:00", "16:30:00", 30, false, `{"start_at": "plan", "end_at": "clock", "break_minutes": "standard", "standard_minutes": "standard", "no_break": "self"}`), true},
		{"day no times", day("2026-10-02", "", "", 0, false, `{}`), true},
		{"day no break", day("2026-10-03", "08:00:00", "12:00:00", 0, true, `{"no_break": "foreman"}`), true},
		{"day no break with a break", day("2026-10-04", "08:00:00", "12:00:00", 30, true, `{}`), false},
		{"day end before start", day("2026-10-05", "16:00:00", "08:00:00", 0, false, `{}`), false},
		{"day end equals start", day("2026-10-06", "08:00:00", "08:00:00", 0, false, `{}`), false},
		{"day break 1441", day("2026-10-07", "", "", 1441, false, `{}`), false},
		{"day unknown source", day("2026-10-08", "", "", 0, false, `{"start_at": "guess"}`), false},
		{"day unknown field", day("2026-10-09", "", "", 0, false, `{"rate": "plan"}`), false},
		{"day source not a string", day("2026-10-10", "", "", 0, false, `{"start_at": 1}`), false},
		{"day sources an array", day("2026-10-11", "", "", 0, false, `["plan"]`), false},
		{"change member", change("HUM-1", "member", "entry", "'late'"), true},
		{"change terminal", change("term-1", "terminal", "clock", "NULL"), true},
		{"change sweep", change("sweep", "sweep", "period", "NULL"), true},
		{"change sweep kind, other actor", change("HUM-1", "sweep", "period", "NULL"), false},
		{"change actor kind", change("HUM-1", "admin", "entry", "NULL"), false},
		{"change object shape", change("HUM-1", "member", "Entry!", "NULL"), false},
		{"change reason 501", change("HUM-1", "member", "entry", "'"+strings.Repeat("r", 501)+"'"), false},
		{"adjustment", adj("2026-10-12", "2026-10-01", "work", "job:j1", -30, "double booked"), true},
		{"adjustment travel to a topic", adj("2026-10-12", "2026-10-02", "travel", "t:abc", 45, "missed trip"), true},
		{"adjustment zero minutes", adj("2026-10-12", "2026-10-03", "work", "ws", 0, "nothing"), false},
		{"adjustment 1441", adj("2026-10-12", "2026-10-03", "work", "ws", 1441, "too much"), false},
		{"adjustment blank reason", adj("2026-10-12", "2026-10-03", "work", "ws", 15, "  "), false},
		{"adjustment into its own day's period", adj("2026-10-12", "2026-10-12", "work", "ws", 15, "same day"), false},
		{"adjustment kind", adj("2026-10-12", "2026-10-03", "overtime", "ws", 15, "x"), false},
		{"adjustment target", adj("2026-10-12", "2026-10-03", "work", "issue:1", 15, "x"), false},
	} {
		_, err := pg.execTenant(ctx, tn, c.sql, tn)
		if c.ok && err != nil {
			t.Errorf("%s: refused: %v", c.name, err)
		}
		if !c.ok && pgCode(err) != "23514" {
			t.Errorf("%s: %v, want a CHECK refusal (23514)", c.name, err)
		}
	}
	// FR-35: a replayed op_id is the same key, refused; the store reads it as seen (T029).
	op := `INSERT INTO hours_ops (tenant_id, member_id, op_id) VALUES ($1, 'HUM-1', 'op-1')`
	if _, err := pg.execTenant(ctx, tn, op, tn); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.execTenant(ctx, tn, op, tn); pgCode(err) != "23505" {
		t.Errorf("a replayed op_id: %v, want 23505", err)
	}
}

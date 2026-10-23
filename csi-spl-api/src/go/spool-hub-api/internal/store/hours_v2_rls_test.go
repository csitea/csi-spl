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

// Spec 107 v2 T021 (FR-14, FR-16, FR-18, FR-22, FR-29, FR-37): rdb 0215's
// people and plan tables under row level security, and their CHECKs.
// rls_failclosed_test.go's catalogue gate covers the policies' shape and
// TestCrossTenantEveryTable the unscoped writes (crosstenant_test.go seeds
// one row of each through seedHoursV2Plan); this file proves what each scope
// reads and may write, per table, in the hours_rls_test.go pattern. Postgres
// only (SPOOL_TEST_PG_DSN).

// hoursV2PlanTables are rdb 0215's tables.
var hoursV2PlanTables = []string{"hours_standard_days", "hours_jobs", "hours_crews", "hours_crew_members", "hours_plan", "hours_holidays"}

// seedHoursV2Plan writes one row of each rdb 0215 table for member in
// tenant, under the tenant's own scope (the runtime path: RLS WITH CHECK
// admits it): job j1, crew c1 with member as its worker, and member's plan
// row on job j1 in crew c1 on at's day.
func seedHoursV2Plan(ctx context.Context, pg *Postgres, tenant, member string, at time.Time) error {
	return pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		day := at.UTC().Format("2006-01-02")
		for _, q := range []struct {
			sql  string
			args []any
		}{
			{`INSERT INTO hours_standard_days (tenant_id, member_id, effective_from, mon_minutes, tue_minutes, wed_minutes,
				thu_minutes, fri_minutes, sat_minutes, sun_minutes, updated_by)
				VALUES ($1, $2, $3::date, 480, 480, 480, 480, 0, 0, 0, 'HUM-9')`, []any{tenant, member, day}},
			{`INSERT INTO hours_jobs (tenant_id, job_id, name, site, quote_minutes, updated_by)
				VALUES ($1, 'j1', 'Roof', 'Main street 1', 2400, 'HUM-9')`, []any{tenant}},
			{`INSERT INTO hours_crews (tenant_id, crew_id, name, updated_by) VALUES ($1, 'c1', 'Crew one', 'HUM-9')`, []any{tenant}},
			{`INSERT INTO hours_crew_members (tenant_id, crew_id, member_id, role, from_day, updated_by)
				VALUES ($1, 'c1', $2, 'worker', $3::date, 'HUM-9')`, []any{tenant, member, day}},
			{`INSERT INTO hours_plan (tenant_id, member_id, day, slot, job_id, start_at, end_at, crew_id, updated_by)
				VALUES ($1, $2, $3::date, 1, 'j1', $3::date + time '07:00', $3::date + time '15:00', 'c1', 'HUM-9')`,
				[]any{tenant, member, day}},
			{`INSERT INTO hours_holidays (tenant_id, day, name, updated_by) VALUES ($1, $2::date, 'Holiday', 'HUM-9')`,
				[]any{tenant, day}},
		} {
			if _, err := tx.Exec(ctx, q.sql, q.args...); err != nil {
				return err
			}
		}
		return nil
	})
}

// hoursV2PlanCounts reads t1's rows of each rdb 0215 table in one fresh
// transaction under scope: "tenant:<id>", "operator", "empty"
// (app.tenant_id = ”) or "none".
func hoursV2PlanCounts(t *testing.T, pg *Postgres, scope, t1 string) string {
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
		for _, tb := range hoursV2PlanTables {
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

// hoursV2PlanWant is the count line with n rows in every table.
func hoursV2PlanWant(n int) string {
	out := ""
	for _, tb := range hoursV2PlanTables {
		out += fmt.Sprintf("%s=%d ", tb, n)
	}
	return out
}

// TestRLSHoursV2PlanScopes, per table: t2's scope, an empty scope and no
// scope read none of t1's rows (fail-closed); t1's scope and the operator
// read all of them; a t1 row written under t2's scope fails WITH CHECK
// (42501), and an UPDATE or DELETE of t1's rows under t2's scope touches
// none. t2's plan row cannot name t1's job (the FK carries tenant_id). A
// tenant delete takes every row with it. CONTROL: with FORCE lifted (rolled
// back) the owner reads t1's row under t2's scope, per table, so the zeros
// above are the policy's.
func TestRLSHoursV2PlanScopes(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	t1, t2 := newTenant(t, pg), newTenant(t, pg)
	now := time.Now().UTC()
	if err := seedHoursV2Plan(ctx, pg, t1, "HUM-1", now); err != nil {
		t.Fatal(err)
	}
	all, none := hoursV2PlanWant(1), hoursV2PlanWant(0)
	for _, c := range []struct{ scope, want string }{
		{"tenant:" + t2, none}, {"empty", none}, {"none", none}, {"tenant:" + t1, all}, {"operator", all},
	} {
		if got := hoursV2PlanCounts(t, pg, c.scope, t1); got != c.want {
			t.Errorf("scope %s reads %s, want %s", c.scope, got, c.want)
		}
	}
	if err := seedHoursV2Plan(ctx, pg, t2, "HUM-1", now); err != nil { // t2's own rows: admitted
		t.Fatalf("t2's own rows: %v", err)
	}
	for _, w := range []string{
		`INSERT INTO hours_standard_days (tenant_id, member_id, effective_from, mon_minutes, tue_minutes, wed_minutes, thu_minutes, fri_minutes, sat_minutes, sun_minutes, updated_by) VALUES ($1, 'HUM-2', current_date, 1, 1, 1, 1, 1, 1, 1, 'HUM-9')`,
		`INSERT INTO hours_jobs (tenant_id, job_id, name, updated_by) VALUES ($1, 'j2', 'Wall', 'HUM-9')`,
		`INSERT INTO hours_crews (tenant_id, crew_id, name, updated_by) VALUES ($1, 'c2', 'Crew two', 'HUM-9')`,
		`INSERT INTO hours_crew_members (tenant_id, crew_id, member_id, role, from_day, updated_by) VALUES ($1, 'c1', 'HUM-2', 'foreman', current_date, 'HUM-9')`,
		`INSERT INTO hours_plan (tenant_id, member_id, day, slot, job_id, start_at, end_at, updated_by) VALUES ($1, 'HUM-1', current_date, 2, 'j1', current_date + time '16:00', current_date + time '18:00', 'HUM-9')`,
		`INSERT INTO hours_holidays (tenant_id, region, day, name, updated_by) VALUES ($1, 'north', current_date, 'Holiday', 'HUM-9')`,
	} {
		if _, err := pg.execTenant(ctx, t2, w, t1); pgCode(err) != "42501" {
			t.Errorf("a t1 row written under t2's scope: %v (want WITH CHECK, 42501)\n%s", err, w)
		}
	}
	// t2's own plan row naming a job only t1 holds: the composite FK refuses it.
	if _, err := pg.execTenant(ctx, t2, `INSERT INTO hours_jobs (tenant_id, job_id, name, updated_by) VALUES ($1, 'only-t1', 'X', 'HUM-9')`, t1); pgCode(err) != "42501" {
		t.Fatalf("t1's job under t2's scope: %v", err)
	}
	if _, err := pg.execTenant(ctx, t1, `INSERT INTO hours_jobs (tenant_id, job_id, name, updated_by) VALUES ($1, 'only-t1', 'X', 'HUM-9')`, t1); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.execTenant(ctx, t2, `INSERT INTO hours_plan (tenant_id, member_id, day, slot, job_id, start_at, end_at, updated_by)
		VALUES ($1, 'HUM-3', current_date, 1, 'only-t1', current_date + time '07:00', current_date + time '08:00', 'HUM-9')`, t2); pgCode(err) != "23503" {
		t.Errorf("t2's plan row on t1's job: %v, want the FK refusal (23503)", err)
	}
	if _, err := pg.execTenant(ctx, t1, `DELETE FROM hours_jobs WHERE tenant_id = $1 AND job_id = 'only-t1'`, t1); err != nil {
		t.Fatal(err)
	}
	for _, tb := range hoursV2PlanTables {
		tag, err := pg.execTenant(ctx, t2, `UPDATE `+tb+` SET updated_by = 'HUM-X' WHERE tenant_id = $1`, t1)
		if err != nil || tag.RowsAffected() != 0 {
			t.Errorf("t2's scope updated %d %s rows of t1: %v", tag.RowsAffected(), tb, err)
		}
		tag, err = pg.execTenant(ctx, t2, `DELETE FROM `+tb+` WHERE tenant_id = $1`, t1)
		if err != nil || tag.RowsAffected() != 0 {
			t.Errorf("t2's scope deleted %d %s rows of t1: %v", tag.RowsAffected(), tb, err)
		}
	}
	if got := hoursV2PlanCounts(t, pg, "operator", t1); got != all {
		t.Fatalf("after t2's writes t1 holds %s, want %s", got, all)
	}
	for _, tb := range hoursV2PlanTables {
		hoursV2PlanLiftControl(t, pg, tb, t1, t2)
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = $1`, t1)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if got := hoursV2PlanCounts(t, pg, "operator", t1); got != none {
		t.Fatalf("after the tenant delete: %s", got)
	}
	if got := hoursV2PlanCounts(t, pg, "operator", t2); got != all {
		t.Fatalf("t1's delete touched t2: %s, want %s", got, all)
	}
}

// hoursV2PlanLiftControl lifts FORCE on tb in a rolled-back transaction:
// the owner then reads t1's row of tb under t2's scope.
func hoursV2PlanLiftControl(t *testing.T, pg *Postgres, tb, t1, t2 string) {
	t.Helper()
	ctx := context.Background()
	var n int
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
		for _, q := range []string{`ALTER TABLE ` + tb + ` NO FORCE ROW LEVEL SECURITY`, `SELECT set_config('app.tenant_id', '` + t2 + `', true)`} {
			if _, err := tx.Exec(ctx, q); err != nil {
				return err
			}
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM `+tb+` WHERE tenant_id = $1`, t1).Scan(&n); err != nil {
			return err
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) {
		t.Fatalf("%s control: %v", tb, err)
	}
	if n != 1 {
		t.Fatalf("CONTROL: without FORCE the owner read %d of t1's %s rows under t2's scope, want 1", n, tb)
	}
}

// TestHoursV2PlanChecks: the CHECKs, keys and FKs of rdb 0215 refuse what
// they must and admit the edge that is valid; each write runs in the
// tenant's scope, on top of seedHoursV2Plan's rows (job j1, crew c1 with
// HUM-1 as its open worker since 2026-10-05).
func TestHoursV2PlanChecks(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := newTenant(t, pg)
	if err := seedHoursV2Plan(ctx, pg, tn, "HUM-1", time.Date(2026, 10, 5, 9, 0, 0, 0, time.UTC)); err != nil {
		t.Fatal(err)
	}
	std := func(from string, mins [7]int, overtime string) string {
		return fmt.Sprintf(`INSERT INTO hours_standard_days (tenant_id, member_id, effective_from, mon_minutes, tue_minutes, wed_minutes,
			thu_minutes, fri_minutes, sat_minutes, sun_minutes, overtime_weekly_minutes, updated_by)
			VALUES ($1, 'HUM-2', '%s', %d, %d, %d, %d, %d, %d, %d, %s, 'HUM-9')`,
			from, mins[0], mins[1], mins[2], mins[3], mins[4], mins[5], mins[6], overtime)
	}
	job := func(id, name, state, quote string) string {
		return `INSERT INTO hours_jobs (tenant_id, job_id, name, state, quote_minutes, updated_by) VALUES ($1, '` + id + `', '` + name + `', '` + state + `', ` + quote + `, 'HUM-9')`
	}
	member := func(crew, hum, role, from, to string) string {
		return `INSERT INTO hours_crew_members (tenant_id, crew_id, member_id, role, from_day, to_day, updated_by)
			VALUES ($1, '` + crew + `', '` + hum + `', '` + role + `', '` + from + `', ` + to + `, 'HUM-9')`
	}
	plan := func(hum, day string, slot int, jobID, start, end string) string {
		return fmt.Sprintf(`INSERT INTO hours_plan (tenant_id, member_id, day, slot, job_id, start_at, end_at, explicit, updated_by)
			VALUES ($1, '%s', '%s', %d, '%s', '%s', '%s', false, 'HUM-9')`, hum, day, slot, jobID, start, end)
	}
	holiday := func(region, day, name, minutes string) string {
		return `INSERT INTO hours_holidays (tenant_id, region, day, name, minutes, updated_by) VALUES ($1, '` + region + `', '` + day + `', '` + name + `', ` + minutes + `, 'HUM-9')`
	}
	full := [7]int{480, 480, 480, 480, 480, 0, 0}
	for _, c := range []struct {
		name, sql, code string // code "" = admitted
	}{
		{"standard day 4 x 480 and Friday 0", std("2026-10-05", [7]int{480, 480, 480, 480, 0, 0, 0}, "NULL"), ""},
		{"standard day all 0", std("2026-10-12", [7]int{}, "NULL"), ""},
		{"standard day 1440 and an overtime threshold", std("2026-10-19", [7]int{1440, 0, 0, 0, 0, 0, 0}, "2400"), ""},
		{"standard day same member and date", std("2026-10-05", full, "NULL"), "23505"},
		{"standard day 1441", std("2026-10-26", [7]int{0, 0, 0, 0, 0, 0, 1441}, "NULL"), "23514"},
		{"standard day negative", std("2026-11-02", [7]int{-1, 0, 0, 0, 0, 0, 0}, "NULL"), "23514"},
		{"standard day overtime negative", std("2026-11-09", full, "-1"), "23514"},
		{"standard day overtime above a week", std("2026-11-16", full, "10081"), "23514"},
		{"job open, no quote", job("j-2", "Wall", "open", "NULL"), ""},
		{"job closed", job("j.3", "Floor", "closed", "0"), ""},
		{"job same id", job("j1", "Again", "open", "NULL"), "23505"},
		{"job state", job("j4", "Gate", "paused", "NULL"), "23514"},
		{"job blank name", job("j5", "  ", "open", "NULL"), "23514"},
		{"job id with a colon", job("j:6", "Door", "open", "NULL"), "23514"},
		{"job id empty", job("", "Door", "open", "NULL"), "23514"},
		{"job negative quote", job("j7", "Door", "open", "-1"), "23514"},
		{"crew foreman, open", member("c1", "HUM-8", "foreman", "2026-10-01", "NULL"), ""},
		{"crew a second open worker row", member("c1", "HUM-1", "worker", "2026-10-12", "NULL"), "23505"},
		{"crew a closed worker row before", member("c1", "HUM-1", "worker", "2026-09-01", "'2026-09-30'"), ""},
		{"crew to_day before from_day", member("c1", "HUM-3", "worker", "2026-10-05", "'2026-10-04'"), "23514"},
		{"crew role", member("c1", "HUM-3", "boss", "2026-10-05", "NULL"), "23514"},
		{"crew unknown crew", member("c9", "HUM-3", "worker", "2026-10-05", "NULL"), "23503"},
		{"plan slot 2", plan("HUM-1", "2026-10-05", 2, "j1", "2026-10-05T15:00:00Z", "2026-10-05T17:00:00Z"), ""},
		{"plan slot 3", plan("HUM-1", "2026-10-06", 3, "j1", "2026-10-06T07:00:00Z", "2026-10-06T08:00:00Z"), "23514"},
		{"plan slot 0", plan("HUM-1", "2026-10-06", 0, "j1", "2026-10-06T07:00:00Z", "2026-10-06T08:00:00Z"), "23514"},
		{"plan same slot twice", plan("HUM-1", "2026-10-05", 1, "j1", "2026-10-05T05:00:00Z", "2026-10-05T06:00:00Z"), "23505"},
		{"plan end before start", plan("HUM-1", "2026-10-07", 1, "j1", "2026-10-07T08:00:00Z", "2026-10-07T07:00:00Z"), "23514"},
		{"plan longer than a day", plan("HUM-1", "2026-10-07", 1, "j1", "2026-10-07T00:00:00Z", "2026-10-08T00:01:00Z"), "23514"},
		{"plan start with seconds", plan("HUM-1", "2026-10-07", 1, "j1", "2026-10-07T07:00:30Z", "2026-10-07T08:00:00Z"), "23514"},
		{"plan unknown job", plan("HUM-1", "2026-10-07", 1, "nope", "2026-10-07T07:00:00Z", "2026-10-07T08:00:00Z"), "23503"},
		{"holiday part day in a region", holiday("north", "2026-12-24", "Christmas Eve", "240"), ""},
		{"holiday same region and day", holiday("north", "2026-12-24", "Again", "NULL"), "23505"},
		{"holiday 0 minutes", holiday("", "2026-12-25", "Christmas", "0"), "23514"},
		{"holiday 1441 minutes", holiday("", "2026-12-26", "Boxing Day", "1441"), "23514"},
		{"holiday blank name", holiday("", "2026-12-31", " ", "NULL"), "23514"},
	} {
		_, err := pg.execTenant(ctx, tn, c.sql, tn)
		if c.code == "" && err != nil {
			t.Errorf("%s: refused: %v", c.name, err)
		}
		if c.code != "" && pgCode(err) != c.code {
			t.Errorf("%s: %v, want %s", c.name, err, c.code)
		}
	}
	// A worker moved: close the open row, then a new open row in another crew is admitted.
	for _, q := range []string{
		`INSERT INTO hours_crews (tenant_id, crew_id, name, updated_by) VALUES ($1, 'c2', 'Crew two', 'HUM-9')`,
		`UPDATE hours_crew_members SET to_day = '2026-10-11' WHERE tenant_id = $1 AND member_id = 'HUM-1' AND role = 'worker' AND to_day IS NULL`,
		member("c2", "HUM-1", "worker", "2026-10-12", "NULL"),
	} {
		if _, err := pg.execTenant(ctx, tn, q, tn); err != nil {
			t.Fatalf("worker move: %v\n%s", err, q)
		}
	}
	// A deleted job takes its plan rows; a deleted crew its member rows.
	var plans, members int
	if err := pg.inTenant(ctx, tn, func(tx pgx.Tx) error {
		for _, q := range []string{`DELETE FROM hours_jobs WHERE tenant_id = $1 AND job_id = 'j1'`, `DELETE FROM hours_crews WHERE tenant_id = $1 AND crew_id = 'c1'`} {
			if _, err := tx.Exec(ctx, q, tn); err != nil {
				return err
			}
		}
		return tx.QueryRow(ctx, `SELECT (SELECT count(*) FROM hours_plan WHERE tenant_id = $1), (SELECT count(*) FROM hours_crew_members WHERE tenant_id = $1 AND crew_id = 'c1')`, tn).Scan(&plans, &members)
	}); err != nil || plans != 0 || members != 0 {
		t.Fatalf("after deleting j1 and c1: %d plan row(s), %d c1 member row(s) (%v); want 0, 0", plans, members, err)
	}
}

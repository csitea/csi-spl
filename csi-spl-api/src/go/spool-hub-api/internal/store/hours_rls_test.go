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

// Spec 107 T002 (sections 3.2, 3.3, 6.1): rdb 0151's three hours tables
// under row level security, their CHECKs, and the two widenings that file
// makes. rls_failclosed_test.go's catalogue gate covers the policies' shape
// and TestCrossTenantEveryTable the unscoped writes (crosstenant_test.go
// seeds one row of each); this file proves what each scope reads and may
// write. Postgres only (SPOOL_TEST_PG_DSN).

// hoursTables are rdb 0151's tables.
var hoursTables = []string{"hours_minutes", "hours_entries", "hours_periods"}

// seedHours writes one row of each hours table for member in tenant, under
// the tenant's own scope (the runtime path: RLS WITH CHECK admits it).
func seedHours(ctx context.Context, pg *Postgres, tenant, member string, at time.Time) error {
	return pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		day := at.UTC().Format("2006-01-02")
		for _, q := range []struct {
			sql  string
			args []any
		}{
			{`INSERT INTO hours_minutes (tenant_id, member_id, minute, target, src, tz)
				VALUES ($1, $2, date_trunc('minute', $3::timestamptz, 'UTC'), 'ch:lobby', 'tab', 'UTC')`, []any{tenant, member, at}},
			{`INSERT INTO hours_entries (tenant_id, member_id, day, target, minutes, suggested_minutes, state, updated_by)
				VALUES ($1, $2, $3::date, 'ws', 15, 15, 'approved', $2)`, []any{tenant, member, day}},
			{`INSERT INTO hours_periods (tenant_id, member_id, period_start, period_end, state, minutes, decided_by)
				VALUES ($1, $2, $3::date, $3::date + 6, 'frozen', 15, 'sweep')`, []any{tenant, member, day}},
		} {
			if _, err := tx.Exec(ctx, q.sql, q.args...); err != nil {
				return err
			}
		}
		return nil
	})
}

// hoursCounts reads t1's rows of each hours table in one fresh transaction
// under scope: "tenant:<id>", "operator", "empty" (app.tenant_id = ”) or
// "none".
func hoursCounts(t *testing.T, pg *Postgres, scope, t1 string) string {
	t.Helper()
	ctx := context.Background()
	out := ""
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) (err error) {
		switch {
		case scope == "operator":
			_, err = tx.Exec(ctx, pgScopeOperator)
		case scope == "empty":
			_, err = tx.Exec(ctx, pgScopeTenant, "")
		case len(scope) > 7 && scope[:7] == "tenant:":
			_, err = tx.Exec(ctx, pgScopeTenant, scope[7:])
		}
		if err != nil {
			return err
		}
		for _, tb := range hoursTables {
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

// TestRLSHoursScopes: t2's scope, an empty scope and no scope read none of
// t1's hours rows (fail-closed); t1's scope and the operator read all of
// them; a t1 row written under t2's scope fails WITH CHECK (42501), and an
// UPDATE of t1's rows under t2's scope touches none. A tenant delete takes
// its hours rows with it. CONTROL: with FORCE lifted (rolled back) the owner
// reads t1's minutes under t2's scope, so the zeros above are the policy's.
func TestRLSHoursScopes(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	t1, t2 := newTenant(t, pg), newTenant(t, pg)
	now := time.Now().UTC()
	if err := seedHours(ctx, pg, t1, "HUM-1", now); err != nil {
		t.Fatal(err)
	}
	all, none := "hours_minutes=1 hours_entries=1 hours_periods=1 ", "hours_minutes=0 hours_entries=0 hours_periods=0 "
	for _, c := range []struct{ scope, want string }{
		{"tenant:" + t2, none}, {"empty", none}, {"none", none}, {"tenant:" + t1, all}, {"operator", all},
	} {
		if got := hoursCounts(t, pg, c.scope, t1); got != c.want {
			t.Errorf("scope %s reads %s, want %s", c.scope, got, c.want)
		}
	}
	if err := seedHours(ctx, pg, t2, "HUM-1", now); err != nil { // t2's own rows: admitted
		t.Fatalf("t2's own rows: %v", err)
	}
	for _, w := range []string{
		`INSERT INTO hours_minutes (tenant_id, member_id, minute, target, src, tz) VALUES ($1, 'HUM-2', date_trunc('minute', now(), 'UTC'), 'ws', 'post', 'UTC')`,
		`INSERT INTO hours_entries (tenant_id, member_id, day, target, minutes, state, updated_by) VALUES ($1, 'HUM-2', current_date, 'ws', 1, 'approved', 'HUM-2')`,
		`INSERT INTO hours_periods (tenant_id, member_id, period_start, period_end, state, decided_by) VALUES ($1, 'HUM-2', current_date, current_date, 'frozen', 'sweep')`,
	} {
		if _, err := pg.execTenant(ctx, t2, w, t1); pgCode(err) != "42501" {
			t.Errorf("a t1 row written under t2's scope: %v (want WITH CHECK, 42501)\n%s", err, w)
		}
	}
	for _, tb := range hoursTables {
		tag, err := pg.execTenant(ctx, t2, `UPDATE `+tb+` SET member_id = 'HUM-X' WHERE tenant_id = $1`, t1)
		if err != nil || tag.RowsAffected() != 0 {
			t.Errorf("t2's scope updated %d %s rows of t1: %v", tag.RowsAffected(), tb, err)
		}
		tag, err = pg.execTenant(ctx, t2, `DELETE FROM `+tb+` WHERE tenant_id = $1`, t1)
		if err != nil || tag.RowsAffected() != 0 {
			t.Errorf("t2's scope deleted %d %s rows of t1: %v", tag.RowsAffected(), tb, err)
		}
	}
	if got := hoursCounts(t, pg, "operator", t1); got != all {
		t.Fatalf("after t2's writes t1 holds %s, want %s", got, all)
	}
	hoursLiftControl(t, pg, t1, t2)
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = $1`, t1)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if got := hoursCounts(t, pg, "operator", t1); got != none {
		t.Fatalf("after the tenant delete: %s", got)
	}
}

// hoursLiftControl lifts FORCE on hours_minutes in a rolled-back
// transaction: the owner then reads t1's minute under t2's scope.
func hoursLiftControl(t *testing.T, pg *Postgres, t1, t2 string) {
	t.Helper()
	ctx := context.Background()
	var n int
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
		for _, q := range []string{`ALTER TABLE hours_minutes NO FORCE ROW LEVEL SECURITY`, `SELECT set_config('app.tenant_id', '` + t2 + `', true)`} {
			if _, err := tx.Exec(ctx, q); err != nil {
				return err
			}
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM hours_minutes WHERE tenant_id = $1`, t1).Scan(&n); err != nil {
			return err
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) {
		t.Fatalf("control: %v", err)
	}
	if n != 1 {
		t.Fatalf("CONTROL: without FORCE the owner read %d of t1's minutes under t2's scope, want 1", n)
	}
}

// TestHoursChecks: the CHECKs of spec 3.2 refuse what they must (23514) and
// admit the edge that is valid; each insert runs in the tenant's scope.
func TestHoursChecks(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := newTenant(t, pg)
	long := "t:" + strings.Repeat("x", 201)
	minute := func(ts, target, src string) string {
		return `INSERT INTO hours_minutes (tenant_id, member_id, minute, target, src, tz) VALUES ($1, 'HUM-1', '` + ts + `', '` + target + `', '` + src + `', 'Europe/Helsinki')`
	}
	entry := func(day, target string, minutes, sugg int, state string) string {
		return fmt.Sprintf(`INSERT INTO hours_entries (tenant_id, member_id, day, target, minutes, suggested_minutes, state, updated_by)
			VALUES ($1, 'HUM-1', '%s', '%s', %d, %d, '%s', 'HUM-1')`, day, target, minutes, sugg, state)
	}
	period := func(start, end, state, note string) string {
		n := "NULL"
		if note != "" {
			n = "'" + note + "'"
		}
		return `INSERT INTO hours_periods (tenant_id, member_id, period_start, period_end, state, decided_by, note)
			VALUES ($1, 'HUM-1', '` + start + `', '` + end + `', '` + state + `', 'HUM-9', ` + n + `)`
	}
	for _, c := range []struct {
		name, sql string
		ok        bool
	}{
		{"minute on the minute", minute("2026-10-07T09:46:00Z", "t:abc", "post"), true},
		{"minute with seconds", minute("2026-10-07T09:47:30Z", "t:abc", "tab"), false},
		{"minute with micros", minute("2026-10-07T09:48:00.5Z", "t:abc", "tab"), false},
		{"minute target ws", minute("2026-10-07T09:49:00Z", "ws", "tab"), true},
		{"minute target ch", minute("2026-10-07T09:50:00Z", "ch:lobby", "tab"), true},
		{"minute target dm", minute("2026-10-07T09:51:00Z", "dm:HUM-2", "tab"), true},
		{"minute target cal is entries only", minute("2026-10-07T09:52:00Z", "cal:ev1", "tab"), false},
		{"minute target empty id", minute("2026-10-07T09:53:00Z", "t:", "tab"), false},
		{"minute target 201 chars", minute("2026-10-07T09:54:00Z", long, "tab"), false},
		{"minute target unknown prefix", minute("2026-10-07T09:55:00Z", "x:1", "tab"), false},
		{"minute src", minute("2026-10-07T09:56:00Z", "ws", "meeting"), false},
		{"entry cal", entry("2026-10-06", "cal:ev1", 30, 30, "approved"), true},
		{"entry 1440", entry("2026-10-06", "ws", 1440, 0, "rejected"), true},
		{"entry 1441", entry("2026-10-06", "t:a", 1441, 0, "approved"), false},
		{"entry negative", entry("2026-10-06", "t:b", -1, 0, "approved"), false},
		{"entry suggested 1441", entry("2026-10-06", "t:c", 0, 1441, "approved"), false},
		{"entry state", entry("2026-10-06", "t:d", 10, 10, "open"), false},
		{"entry target", entry("2026-10-06", "issue:1", 10, 10, "approved"), false},
		{"period frozen", period("2026-09-28", "2026-10-04", "frozen", ""), true},
		{"period returned with note", period("2026-09-21", "2026-09-27", "returned", "fix Tuesday"), true},
		{"period returned without note", period("2026-09-14", "2026-09-20", "returned", ""), false},
		{"period returned blank note", period("2026-09-07", "2026-09-13", "returned", "  "), false},
		{"period end before start", period("2026-08-31", "2026-08-30", "frozen", ""), false},
		{"period state", period("2026-08-24", "2026-08-30", "open", ""), false},
	} {
		_, err := pg.execTenant(ctx, tn, c.sql, tn)
		if c.ok && err != nil {
			t.Errorf("%s: refused: %v", c.name, err)
		}
		if !c.ok && pgCode(err) != "23514" {
			t.Errorf("%s: %v, want a CHECK refusal (23514)", c.name, err)
		}
	}
	// The natural key: a second write of the same (member, day, target) is an upsert.
	if _, err := pg.execTenant(ctx, tn, entry("2026-10-06", "cal:ev1", 45, 30, "approved")+
		` ON CONFLICT (tenant_id, member_id, day, target) DO UPDATE SET minutes = EXCLUDED.minutes`, tn); err != nil {
		t.Fatalf("upsert: %v", err)
	}
	var n, m int
	if err := pg.inTenant(ctx, tn, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*), max(minutes) FROM hours_entries WHERE tenant_id = $1 AND target = 'cal:ev1'`, tn).Scan(&n, &m)
	}); err != nil || n != 1 || m != 45 {
		t.Fatalf("upsert left %d row(s), minutes %d (%v); want 1, 45", n, m, err)
	}
}

// TestHoursWidenings: member_activity takes 'hours_returned' and the 90-day
// auth sweep keeps it while it prunes an old sign_in (CONTROL); a 12-entry
// rail order with 'hours' is admitted, an 11-entry one still is, and a
// 12-entry order without 'hours' is refused. Written as SQL: the store's
// checkRailOrder (auth.RailTabs) learns 'hours' with the rail task (T011).
func TestHoursWidenings(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := newTenant(t, pg)
	var hum string
	if err := pg.pool.QueryRow(ctx, `INSERT INTO humans (display_name, created_at) VALUES ('FirstName LastName', now()) RETURNING human_id`).Scan(&hum); err != nil {
		t.Fatal(err)
	}
	old := time.Now().UTC().Add(-100 * 24 * time.Hour)
	for _, k := range []string{"hours_returned", "sign_in"} {
		if err := pg.AppendMemberActivity(ctx, MemberActivity{TenantID: tn, SubjectHum: hum, ActorHum: hum, Kind: k, Detail: "week 40", CreatedAt: old}); err != nil {
			t.Fatalf("%s: %v", k, err)
		}
	}
	if err := pg.AppendMemberActivity(ctx, MemberActivity{TenantID: tn, SubjectHum: hum, ActorHum: hum, Kind: "hours_approved", CreatedAt: old}); pgCode(err) != "23514" {
		t.Fatalf("an unknown kind: %v, want 23514", err)
	}
	if _, err := pg.SweepMemberActivity(ctx, time.Now().UTC().Add(-90*24*time.Hour)); err != nil {
		t.Fatal(err)
	}
	rows, err := pg.ListMemberActivity(ctx, tn, hum)
	if err != nil {
		t.Fatal(err)
	}
	kinds := map[string]int{}
	for _, r := range rows {
		kinds[r.Kind]++
	}
	if kinds["hours_returned"] != 1 || kinds["sign_in"] != 0 {
		t.Fatalf("after the 90-day sweep: %v, want hours_returned kept and sign_in pruned", kinds)
	}
	eleven := []string{"dm", "channels", "issues", "topics", "flow", "events", "archive", "people", "agents", "boxes", "calendar"}
	for _, c := range []struct {
		name  string
		order []string
		ok    bool
	}{
		{"11 entries", eleven, true},
		{"12 with hours", append([]string{"hours"}, eleven...), true},
		{"12 without hours", append(append([]string{}, eleven...), "dm"), false},
		{"12 with an unknown", append(append([]string{}, eleven...), "minutes"), false},
	} {
		_, err := pg.pool.Exec(ctx, `UPDATE humans SET rail_order = $2 WHERE human_id = $1`, hum, c.order)
		if c.ok != (err == nil) || (!c.ok && pgCode(err) != "23514") {
			t.Errorf("%s: %v (ok want %v)", c.name, err, c.ok)
		}
	}
}

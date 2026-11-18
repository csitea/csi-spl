package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// rdb 0295 (spec 107 21.5, 21.6, 21.8; T071, SPL-5913): member_hourly_prices
// and commit_human_time. Postgres only (rlsStore). No store API yet (T072,
// T075), so the rows are written raw under the scope each test names.

const hoursPriceOther = "44444444-4444-4444-8444-444444444444"

func insertPrice(member string) string {
	return `INSERT INTO member_hourly_prices (tenant_id, member_id, valid_from, amount_micros, currency, set_by)
		VALUES ($1, '` + member + `', '2026-11-01', 60000000, 'EUR', 'HUM-owner')`
}

// scopedCount counts table's rows of workspace of, with no other predicate,
// in one fresh transaction under scope: "tenant" (tenant), "member" (tenant
// and member), "operator", "empty" (app.tenant_id = ”) or "none".
func scopedCount(t *testing.T, pg *Postgres, scope, tenant, member, table, of string) int {
	t.Helper()
	ctx := context.Background()
	var n int
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) (err error) {
		switch scope {
		case "tenant":
			_, err = tx.Exec(ctx, pgScopeTenant, tenant)
		case "member":
			_, err = tx.Exec(ctx, pgScopeMember, tenant, member)
		case "operator":
			_, err = tx.Exec(ctx, pgScopeOperator)
		case "empty":
			_, err = tx.Exec(ctx, pgScopeTenant, "")
		}
		if err != nil {
			return err
		}
		return tx.QueryRow(ctx, `SELECT count(*) FROM `+pgx.Identifier{table}.Sanitize()+` WHERE tenant_id = $1`, of).Scan(&n)
	})
	if err != nil {
		t.Fatalf("count %s under %s: %v", table, scope, err)
	}
	return n
}

// TestRLSHoursPrices: a price written in workspace A reads 0 rows in B's
// scope, an empty and no scope; a write of an A row in B's scope is refused
// (42501). Under member P's scope a statement with no member predicate reads
// P's price only, and a price naming Q is refused; the tenant scope and an
// empty member read both (the biz owner's list). The CHECKs refuse
// amount_micros = 0 and a currency that is not three capitals (23514).
// CONTROL: with member_scope dropped (rolled back), P's scope reads both.
func TestRLSHoursPrices(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	for _, m := range []string{hoursMember, hoursPriceOther} {
		if _, err := pg.execTenant(ctx, a, insertPrice(m), a); err != nil {
			t.Fatalf("A's price of %s: %v", m, err)
		}
	}
	const tb = "member_hourly_prices"
	for _, c := range []struct {
		scope, tenant, member string
		want                  int
	}{
		{"tenant", a, "", 2}, {"tenant", b, "", 0}, {"empty", "", "", 0}, {"none", "", "", 0},
		{"operator", "", "", 2}, {"member", a, hoursMember, 1}, {"member", a, "HUM-nobody", 0},
		{"member", a, "", 2}, {"member", b, hoursMember, 0},
	} {
		if got := scopedCount(t, pg, c.scope, c.tenant, c.member, tb, a); got != c.want {
			t.Errorf("%s %s %s reads %d prices, want %d", c.scope, c.tenant, c.member, got, c.want)
		}
	}
	if _, err := pg.execTenant(ctx, b, insertPrice("HUM-b"), a); pgCode(err) != "42501" {
		t.Errorf("an A price written in B's scope: %v (want 42501)", err)
	}
	if tag, err := pg.execTenant(ctx, b, `UPDATE member_hourly_prices SET amount_micros = 1`); err != nil || tag.RowsAffected() != 0 {
		t.Errorf("B's unscoped UPDATE touched %d A prices: %v", tag.RowsAffected(), err)
	}
	if _, err := pg.execMember(ctx, a, hoursMember, insertPrice("HUM-q-new"), a); pgCode(err) != "42501" {
		t.Errorf("a Q price written under P's scope: %v (want 42501)", err)
	}
	if tag, err := pg.execMember(ctx, a, hoursMember, `DELETE FROM member_hourly_prices WHERE member_id = $1`, hoursPriceOther); err != nil || tag.RowsAffected() != 0 {
		t.Errorf("P's scope deleted %d of Q's prices: %v", tag.RowsAffected(), err)
	}
	for _, bad := range []string{
		`INSERT INTO member_hourly_prices (tenant_id, member_id, valid_from, amount_micros, currency, set_by) VALUES ($1, 'HUM-z', '2026-11-02', 0, 'EUR', 'HUM-owner')`,
		`INSERT INTO member_hourly_prices (tenant_id, member_id, valid_from, amount_micros, currency, set_by) VALUES ($1, 'HUM-z', '2026-11-02', 1, 'eur', 'HUM-owner')`,
	} {
		if _, err := pg.execTenant(ctx, a, bad, a); pgCode(err) != "23514" {
			t.Errorf("CHECK: %v (want 23514)\n%s", err, bad)
		}
	}
	if got := scopedCount(t, pg, "tenant", a, "", tb, a); got != 2 {
		t.Fatalf("after the refused writes A holds %d prices, want 2", got)
	}
	// CONTROL: member_scope dropped in a rolled-back transaction.
	var n int
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `DROP POLICY member_scope ON member_hourly_prices`); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, pgScopeMember, a, hoursMember); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM member_hourly_prices WHERE tenant_id = $1`, a).Scan(&n); err != nil {
			return err
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) {
		t.Fatalf("control: %v", err)
	}
	if n != 2 {
		t.Fatalf("CONTROL: without member_scope P's scope read %d prices, want 2", n)
	}
}

// TestRLSCommitHumanTime: the ledger is written in the operator scope only
// (a tenant INSERT is 42501, its UPDATE / DELETE touch 0 rows) and read in
// the workspace's own scope (B, empty and no scope read 0). Its key holds one
// unpriced row per (commit, day): a second currency NULL row is 23505. An
// amount without a currency is 23514, a sha that is not a release note 23503,
// and deleting the note takes its rows (cascade).
func TestRLSCommitHumanTime(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	repo, sha, now := "csitea/repo-"+a, randSHA(), time.Now().UTC()
	if err := pg.PutReleaseNotes(ctx, a, repo, []ReleaseNote{noteOK(sha, "", now)}, now); err != nil {
		t.Fatal(err)
	}
	const ins = `INSERT INTO commit_human_time (tenant_id, repo_slug, sha, day_bucket, currency, issue_key, minutes, amount_micros)
		VALUES ($1, $2, $3, '2026-11-10', $4, 'SPL-1', 90, $5)`
	op := func(args ...any) error {
		return pg.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, ins, args...)
			return err
		})
	}
	if err := op(a, repo, sha, "EUR", int64(90000000)); err != nil {
		t.Fatalf("priced row: %v", err)
	}
	if err := op(a, repo, sha, nil, nil); err != nil {
		t.Fatalf("unpriced row: %v", err)
	}
	if err := op(a, repo, sha, nil, nil); pgCode(err) != "23505" {
		t.Errorf("a second unpriced row of one (commit, day): %v (want 23505)", err)
	}
	if err := op(a, repo, sha, nil, int64(1)); pgCode(err) != "23514" {
		t.Errorf("an amount without a currency: %v (want 23514)", err)
	}
	if err := op(a, repo, randSHA(), "EUR", int64(1)); pgCode(err) != "23503" {
		t.Errorf("a sha that is not a release note: %v (want 23503)", err)
	}
	const tb = "commit_human_time"
	for _, c := range []struct {
		scope, tenant string
		want          int
	}{{"tenant", a, 2}, {"tenant", b, 0}, {"empty", "", 0}, {"none", "", 0}, {"operator", "", 2}} {
		if got := scopedCount(t, pg, c.scope, c.tenant, "", tb, a); got != c.want {
			t.Errorf("%s %s reads %d ledger rows, want %d", c.scope, c.tenant, got, c.want)
		}
	}
	if _, err := pg.execTenant(ctx, a, ins, a, repo, sha, "USD", int64(1)); pgCode(err) != "42501" {
		t.Errorf("a ledger row written in A's own scope: %v (want 42501)", err)
	}
	for _, w := range []string{`UPDATE commit_human_time SET minutes = 0`, `DELETE FROM commit_human_time`} {
		if tag, err := pg.execTenant(ctx, a, w); err != nil || tag.RowsAffected() != 0 {
			t.Errorf("A's scope: %s touched %d rows: %v", w, tag.RowsAffected(), err)
		}
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM release_notes WHERE tenant_id = $1 AND sha = $2`, a, sha)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if got := scopedCount(t, pg, "operator", "", "", tb, a); got != 0 {
		t.Errorf("after the note's delete %d ledger rows remain, want 0", got)
	}
}

// TestHoursEntriesApprovedTargetIndex: the counter read's partial index.
func TestHoursEntriesApprovedTargetIndex(t *testing.T) {
	pg := rlsStore(t)
	var def string
	if err := pg.pool.QueryRow(context.Background(), `SELECT indexdef FROM pg_indexes
		WHERE schemaname = current_schema() AND indexname = 'hours_entries_approved_target'`).Scan(&def); err != nil {
		t.Fatal(err)
	}
	if want := "hours_entries USING btree (tenant_id, target) WHERE (state = 'approved'::text)"; !strings.Contains(def, want) {
		t.Errorf("index: %s, want it to hold %s", def, want)
	}
}

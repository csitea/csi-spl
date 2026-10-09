package store

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// rdb 0163 (specs/115 RDB-1, spec sections 2 and 3.2): the vendor split per
// task kind, tenant_agent_split_kind. Postgres only; the database is migrated
// through 0163 and the catalogue gate (TestRLS) covers its RLS shape.
//
// Each case writes one kind's rows in its own transaction, under the
// workspace's tenant scope, and reads the CHECK it broke at the statement or
// at commit (the per-kind rules are a deferred constraint trigger).
//   - stored (n=6 kinds, 13 rows, + 1): the spec section 2 table; a kind's rows
//     deleted again (not set).
//   - refused (n=12): agy > 0 or agy the backup in each coding kind (the
//     CONTROL: drop tenant_agent_split_kind_no_agy_coding and this goes red),
//     a secret vendor outside {claude, mistral}, a sum of 99, a tied main, no
//     backup, two backups, the backup = the main, an alias kind.
//   - RLS (n=2): another workspace reads none of the rows and cannot write one.

// splitRow is one kind: vendor -> weight, and the backup.
type splitRow struct {
	kind    string
	weights map[string]int
	backup  string
}

// spec115Rows is the spec 115 section 2 table.
var spec115Rows = []splitRow{
	{"specs_and_docs", map[string]int{"agy": 70, "mistral": 20, "claude": 10}, "claude"},
	{"tests", map[string]int{"claude": 70, "mistral": 30}, "mistral"},
	{"simple_coding", map[string]int{"mistral": 80, "claude": 20}, "claude"},
	{"complex_coding", map[string]int{"claude": 80, "mistral": 20}, "mistral"},
	{"i18n", map[string]int{"agy": 100}, "claude"},
	{"secret", map[string]int{"claude": 100}, "mistral"},
}

func TestTenantAgentSplitKind0163(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()

	// scoped runs fn in one transaction under tenant's scope.
	scoped := func(tenant string, fn func(pgx.Tx) error) error {
		return pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, tenant); err != nil {
				return err
			}
			return fn(tx)
		})
	}
	// write stores rows (vendor, weight, is_backup) of one kind for tenant,
	// scoped as scope, and returns the CHECK it broke ("" if committed).
	write := func(tenant, scope, kind string, rows [][3]any) string {
		t.Helper()
		tx, err := pg.pool.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer tx.Rollback(ctx) //nolint:errcheck
		if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true)`, scope); err != nil {
			t.Fatal(err)
		}
		broke := func(err error) string {
			var pe *pgconn.PgError
			if !errors.As(err, &pe) {
				t.Fatalf("kind %s: %v", kind, err)
			}
			if pe.Code == "42501" {
				return "rls"
			}
			if pe.Code != "23514" {
				t.Fatalf("kind %s: not a CHECK violation: %v", kind, err)
			}
			return pe.ConstraintName
		}
		for _, r := range rows {
			if _, err := tx.Exec(ctx, `INSERT INTO tenant_agent_split_kind (tenant_id, kind, vendor, weight, is_backup)
				VALUES ($1, $2, $3, $4, $5)`, tenant, kind, r[0], r[1], r[2]); err != nil {
				return broke(err)
			}
		}
		if err := tx.Commit(ctx); err != nil {
			return broke(err)
		}
		return ""
	}
	rowsOf := func(r splitRow) [][3]any {
		var out [][3]any
		for v, w := range r.weights {
			out = append(out, [3]any{v, w, v == r.backup})
		}
		if _, ok := r.weights[r.backup]; !ok {
			out = append(out, [3]any{r.backup, 0, true})
		}
		return out
	}

	tenant := newTenant(t, pg)
	for _, r := range spec115Rows {
		if got := write(tenant, tenant, r.kind, rowsOf(r)); got != "" {
			t.Errorf("spec 115 row %s refused by %s", r.kind, got)
		}
	}
	var n int
	if err := scoped(tenant, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FROM tenant_agent_split_kind WHERE tenant_id = $1`, tenant).Scan(&n)
	}); err != nil {
		t.Fatal(err)
	}
	if n != 13 {
		t.Errorf("spec 115 table: %d rows stored, want 13", n)
	}

	const noAgy, secret, rules = "tenant_agent_split_kind_no_agy_coding", "tenant_agent_split_kind_secret_vendors", "tenant_agent_split_kind_rules"
	refused := []struct {
		name, want string
		row        splitRow
	}{
		{"simple_coding agy 10", noAgy, splitRow{"simple_coding", map[string]int{"mistral": 70, "claude": 20, "agy": 10}, "claude"}},
		{"complex_coding agy 10", noAgy, splitRow{"complex_coding", map[string]int{"claude": 80, "mistral": 10, "agy": 10}, "mistral"}},
		{"tests agy 5", noAgy, splitRow{"tests", map[string]int{"claude": 70, "mistral": 25, "agy": 5}, "mistral"}},
		{"tests agy backup", noAgy, splitRow{"tests", map[string]int{"claude": 70, "mistral": 30}, "agy"}},
		{"secret grok 10", secret, splitRow{"secret", map[string]int{"claude": 90, "grok": 10}, "mistral"}},
		{"secret agy backup", secret, splitRow{"secret", map[string]int{"claude": 100}, "agy"}},
		{"sum 99", rules, splitRow{"tests", map[string]int{"claude": 70, "mistral": 29}, "mistral"}},
		{"tied main", rules, splitRow{"complex_coding", map[string]int{"claude": 50, "mistral": 50}, "mistral"}},
		{"backup is main", rules, splitRow{"simple_coding", map[string]int{"mistral": 80, "claude": 20}, "mistral"}},
	}
	for _, c := range refused {
		tn := newTenant(t, pg)
		if got := write(tn, tn, c.row.kind, rowsOf(c.row)); got != c.want {
			t.Errorf("%s: broke %q, want %s", c.name, got, c.want)
		}
	}
	tn := newTenant(t, pg)
	for _, c := range []struct {
		name, kind, want string
		rows             [][3]any
	}{
		{"no backup", "tests", rules, [][3]any{{"claude", 70, false}, {"mistral", 30, false}}},
		{"two backups", "tests", rules, [][3]any{{"claude", 70, false}, {"mistral", 30, true}, {"grok", 0, true}}},
		{"alias kind hard", "hard", "tenant_agent_split_kind_kind_check", [][3]any{{"claude", 100, false}}},
	} {
		if got := write(tn, tn, c.kind, c.rows); got != c.want {
			t.Errorf("%s: broke %q, want %s", c.name, got, c.want)
		}
	}

	// A kind's rows deleted together leave it not set, which is valid.
	if err := scoped(tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM tenant_agent_split_kind WHERE tenant_id = $1 AND kind = 'tests'`, tenant)
		return err
	}); err != nil {
		t.Errorf("deleting the tests kind: %v", err)
	}

	// RLS: another workspace sees none of the rows and cannot write one.
	other := newTenant(t, pg)
	if err := scoped(other, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FROM tenant_agent_split_kind`).Scan(&n)
	}); err != nil {
		t.Fatal(err)
	}
	if n != 0 {
		t.Errorf("RLS: workspace %s reads %d rows of others, want 0", other, n)
	}
	if got := write(tenant, other, "tests", rowsOf(spec115Rows[1])); got != "rls" {
		t.Errorf("RLS: a write into %s scoped as %s broke %q, want an RLS refusal", tenant, other, got)
	}
}

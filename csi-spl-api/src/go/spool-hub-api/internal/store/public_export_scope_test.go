package store

import (
	"context"
	"os"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Fence 2 of the public dataset export (specs/091 T003, spec §5.2; rdb
// 0126, a set of workspaces since 0239). Postgres only (hub-pg.tst.sh). The
// export role spool_public_export sees only the listed workspaces in every
// exported tenant_id table, even with the operator scope set, because a
// RESTRICTIVE policy is AND-ed with the permissive ones. The hub's roles are
// unaffected.

// exportScopeTables are the exported tables that carry tenant_id (§4.1).
var exportScopeTables = []string{"tenants", "channels", "messages", "tenant_memberships"}

// asExportRole runs fn in a rolled-back transaction where the session acts as
// spool_public_export with SELECT on the exported tables (T004 grants the
// columns for real) and public_export_workspace names workspace. The test
// login is the schema owner: it created the role (rdb 0126) and so holds
// ADMIN on it, which lets it grant itself SET for this transaction only.
func asExportRole(t *testing.T, pg *Postgres, workspace string, fn func(ctx context.Context, tx pgx.Tx)) {
	t.Helper()
	asExportRoleAfter(t, pg, workspace, nil, fn)
}

// asExportRoleAfter is asExportRole with first run before anything else in
// the transaction, while it has no transaction id another session could wait
// on (see exportScopeDropControl).
func asExportRoleAfter(t *testing.T, pg *Postgres, workspace string, first []string, fn func(ctx context.Context, tx pgx.Tx)) {
	t.Helper()
	asExportRoleSet(t, pg, []string{workspace}, first, fn)
}

// asExportRoleSet is asExportRoleAfter with public_export_workspace naming
// every one of workspaces (rdb 0239).
func asExportRoleSet(t *testing.T, pg *Postgres, workspaces, first []string, fn func(ctx context.Context, tx pgx.Tx)) {
	t.Helper()
	ctx := context.Background()
	tx, err := pg.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	for _, q := range append(first,
		`GRANT spool_public_export TO CURRENT_USER WITH SET TRUE`,
		`GRANT SELECT ON tenants, channels, messages, tenant_memberships TO spool_public_export`,
	) {
		if _, err := tx.Exec(ctx, q); err != nil {
			t.Fatalf("%s: %v", q, err)
		}
	}
	for _, w := range workspaces {
		if _, err := tx.Exec(ctx, `INSERT INTO public_export_workspace (workspace_id) VALUES ($1)`, w); err != nil {
			t.Fatalf("owner writes public_export_workspace: %v", err)
		}
	}
	if _, err := tx.Exec(ctx, `SET LOCAL ROLE spool_public_export`); err != nil {
		t.Fatal(err)
	}
	fn(ctx, tx)
}

// visible counts the rows of tb this transaction sees with no filter, and
// those of them that are NOT workspace's.
func visible(ctx context.Context, t *testing.T, tx pgx.Tx, tb, workspace string) (all, others int) {
	t.Helper()
	q := `SELECT count(*), count(*) FILTER (WHERE tenant_id <> $1) FROM ` + pgx.Identifier{tb}.Sanitize()
	if err := tx.QueryRow(ctx, q, workspace).Scan(&all, &others); err != nil {
		t.Fatalf("%s: %v", tb, err)
	}
	return all, others
}

func setScope(ctx context.Context, t *testing.T, tx pgx.Tx, tenant, scope string) {
	t.Helper()
	if _, err := tx.Exec(ctx, `SELECT set_config('app.tenant_id', $1, true), set_config('app.rls_scope', $2, true)`, tenant, scope); err != nil {
		t.Fatal(err)
	}
}

// TestPublicExportScopeOneWorkspace: as spool_public_export with a second
// workspace present, a SELECT with no filter returns only the exported
// workspace's rows, with the tenant setting on it, on the other workspace,
// and with app.rls_scope = 'operator'. CONTROLS: the other workspace's rows
// exist (the owner reads them as operator), the export role reads its own
// (not a vacuous zero), and dropping the restrictive policy lets the operator
// scope leak them (so the policy, nothing else, is what holds).
func TestPublicExportScopeOneWorkspace(t *testing.T) {
	pg := rlsStore(t)
	a, b := seedTenantAll(t, pg).tenant, seedTenantAll(t, pg).tenant
	for _, tb := range exportScopeTables {
		if countOf(t, pg, tb, a) == 0 || countOf(t, pg, tb, b) == 0 {
			t.Fatalf("control is void: %s lacks a row of %s or %s", tb, a, b)
		}
	}
	asExportRole(t, pg, a, func(ctx context.Context, tx pgx.Tx) {
		for _, sc := range []struct{ tenant, scope string }{{a, ""}, {b, ""}, {a, "operator"}, {"", "operator"}, {b, "operator"}} {
			setScope(ctx, t, tx, sc.tenant, sc.scope)
			for _, tb := range exportScopeTables {
				all, others := visible(ctx, t, tx, tb, a)
				if others != 0 {
					t.Errorf("tenant=%q scope=%q: spool_public_export sees %d %s row(s) of another workspace", sc.tenant, sc.scope, others, tb)
				}
				if want := countOf(t, pg, tb, a) - exportHidden(t, pg, tb, a); (sc.tenant == a || sc.scope == "operator") && all != want {
					t.Errorf("tenant=%q scope=%q: spool_public_export sees %d %s row(s) of its workspace, want %d", sc.tenant, sc.scope, all, tb, want)
				}
			}
		}
	})
	exportScopeDropControl(t, pg, a)
}

// exportScopeDropControl: with the restrictive policy gone (in a rolled-back
// transaction of its own), the operator scope shows the export role every
// workspace. The transaction locks messages FIRST: DROP POLICY needs ACCESS
// EXCLUSIVE on it, and once the GRANT has rewritten messages' pg_class row an
// ANALYZE of messages (autovacuum's, holding SHARE UPDATE EXCLUSIVE) waits on
// this transaction to update that row - a deadlock (40P01) if the lock is
// taken after the GRANT (CI runs 38097305755, 38102838322, 38103951639).
func exportScopeDropControl(t *testing.T, pg *Postgres, a string) {
	t.Helper()
	asExportRoleAfter(t, pg, a, []string{`LOCK TABLE messages IN ACCESS EXCLUSIVE MODE`}, func(ctx context.Context, tx pgx.Tx) {
		for _, q := range []string{`RESET ROLE`, `DROP POLICY public_export_scope ON messages`, `SET LOCAL ROLE spool_public_export`} {
			if _, err := tx.Exec(ctx, q); err != nil {
				t.Fatalf("%s: %v", q, err)
			}
		}
		setScope(ctx, t, tx, "", "operator")
		if _, others := visible(ctx, t, tx, "messages", a); others == 0 {
			t.Error("control is void: without public_export_scope the operator scope should show other workspaces' messages")
		}
	})
}

// TestPublicExportScopeWorkspaceSet (rdb 0239, SPL-3808): with two of three
// workspaces listed, the export role sees the rows of both and none of the
// third, in each listed workspace's own scope and with the operator scope
// set; in the third's scope it sees nothing. CONTROL: public_export_workspace
// takes the second row (0126's one_row key refused it).
func TestPublicExportScopeWorkspaceSet(t *testing.T) {
	pg := rlsStore(t)
	a, b, c := seedTenantAll(t, pg).tenant, seedTenantAll(t, pg).tenant, seedTenantAll(t, pg).tenant
	asExportRoleSet(t, pg, []string{a, b}, nil, func(ctx context.Context, tx pgx.Tx) {
		for _, sc := range []struct{ tenant, scope string }{{a, ""}, {b, ""}, {c, ""}, {"", "operator"}, {c, "operator"}} {
			setScope(ctx, t, tx, sc.tenant, sc.scope)
			for _, tb := range exportScopeTables {
				var na, nb, nc int
				q := `SELECT count(*) FILTER (WHERE tenant_id = $1), count(*) FILTER (WHERE tenant_id = $2),
					count(*) FILTER (WHERE tenant_id = $3) FROM ` + pgx.Identifier{tb}.Sanitize()
				if err := tx.QueryRow(ctx, q, a, b, c).Scan(&na, &nb, &nc); err != nil {
					t.Fatalf("%s: %v", tb, err)
				}
				if nc != 0 {
					t.Errorf("tenant=%q scope=%q: spool_public_export sees %d %s row(s) of the unlisted workspace", sc.tenant, sc.scope, nc, tb)
				}
				wantA, wantB := sc.tenant == a || sc.scope == "operator", sc.tenant == b || sc.scope == "operator"
				if (na > 0) != wantA || (nb > 0) != wantB {
					t.Errorf("tenant=%q scope=%q: %s rows of the listed workspaces: %d and %d", sc.tenant, sc.scope, tb, na, nb)
				}
			}
		}
	})
}

// TestPublicExportScopeHubUnaffected: the hub's roles (the owner here, and
// the runtime login when hub-pg.tst.sh gives one) still read another
// workspace in its own scope and every workspace as operator, while a
// public_export_workspace row names a different one; neither may write that
// table but the owner.
func TestPublicExportScopeHubUnaffected(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := seedTenantAll(t, pg).tenant, seedTenantAll(t, pg).tenant
	hubs := map[string]*Postgres{"owner": pg}
	if dsn := os.Getenv("SPOOL_TEST_PG_RUNTIME_DSN"); dsn != "" {
		rt, err := OpenPostgres(ctx, dsn)
		if err != nil {
			t.Fatal(err)
		}
		defer rt.Close()
		hubs["runtime"] = rt
	}
	setExportWorkspaces(t, pg, []string{a})
	for name, h := range hubs {
		for _, tb := range exportScopeTables {
			if err := h.inTenant(ctx, b, func(tx pgx.Tx) error {
				all, _ := visible(ctx, t, tx, tb, a)
				if want := countOf(t, pg, tb, b); all != want {
					t.Errorf("%s in workspace %s: sees %d %s row(s), want %d", name, b, all, tb, want)
				}
				return nil
			}); err != nil {
				t.Fatal(err)
			}
			if err := h.asOperator(ctx, func(tx pgx.Tx) error {
				if _, others := visible(ctx, t, tx, tb, a); others == 0 {
					t.Errorf("%s as operator: sees no %s row outside workspace %s", name, tb, a)
				}
				return nil
			}); err != nil {
				t.Fatal(err)
			}
		}
		hubCannotWriteExportWorkspace(ctx, t, name, h, b)
	}
}

// hubCannotWriteExportWorkspace: a non-owner hub login (the runtime role
// holds DML grants on every table) changes no public_export_workspace row.
func hubCannotWriteExportWorkspace(ctx context.Context, t *testing.T, name string, h *Postgres, b string) {
	t.Helper()
	if name == "owner" {
		return
	}
	if err := h.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE public_export_workspace SET workspace_id = $1`, b)
		if err == nil && tag.RowsAffected() != 0 {
			t.Errorf("%s rewrote public_export_workspace (%d row)", name, tag.RowsAffected())
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
}

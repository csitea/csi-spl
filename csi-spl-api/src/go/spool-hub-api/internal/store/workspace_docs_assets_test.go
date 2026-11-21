package store

import (
	"context"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
)

// The pictures of a doc locked to a human stay held for the orphan sweep
// (bug round 34 row 01, SPL-6180; spec 125 B8, rdb 0256 and 0307). The sweep
// reads DocAssetHeld with no human on its context; before rdb 0307 a locked
// doc's root item read as 0 rows there, so its picture read as unnamed and
// was deleted after the 24 h grace. Postgres only (the lock is an RLS
// policy). Fixture data only; no test prints a locked doc's title, item or
// attrs (spec 125 C7-C9): the cases log a name and two booleans.

func TestDocAssetHeldLockedDoc(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	tid, other := newTenant(t, pg), newTenant(t, pg)
	hctx := WithHuman(ctx, "HUM-1")
	// set writes one picture into a root item's attrs.assets
	set := func(c context.Context, tenant, root, sha string) {
		t.Helper()
		err := pg.inTenant(c, tenant, func(tx pgx.Tx) error {
			_, err := tx.Exec(c, `UPDATE workspace_doc_item SET attrs = jsonb_build_object('assets', jsonb_build_object('d.assets/01-a.png', $2::text)) WHERE id = $1`, root, sha)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
	}
	shaOpen, shaLock, shaOther := strings.Repeat("a", 64), strings.Repeat("b", 64), strings.Repeat("d", 64)
	_, rootOpen, err := pg.DocCreateIn(ctx, tid, "", "open doc", "", "HUM-1")
	if err != nil {
		t.Fatal(err)
	}
	set(ctx, tid, rootOpen, shaOpen)
	_, rootLock, err := pg.DocCreateRestricted(hctx, tid, "", "locked doc", "", "HUM-1")
	if err != nil {
		t.Fatal(err)
	}
	set(hctx, tid, rootLock, shaLock)
	// another tenant's locked doc names shaOther: tid never holds it
	_, rootOther, err := pg.DocCreateRestricted(hctx, other, "", "other doc", "", "HUM-1")
	if err != nil {
		t.Fatal(err)
	}
	set(hctx, other, rootOther, shaOther)
	for _, c := range []struct {
		name string
		ctx  context.Context
		sha  string
		want bool
	}{
		{"open", ctx, shaOpen, true},
		{"lockedhuman", hctx, shaLock, true},
		{"lockedsweep", ctx, shaLock, true},
		{"unnamed", ctx, strings.Repeat("c", 64), false},
		{"othertenant", ctx, shaOther, false},
	} {
		got, err := pg.DocAssetHeld(c.ctx, tid, c.sha)
		if err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		t.Logf("pg %s: held=%v want=%v", c.name, got, c.want)
		if got != c.want {
			t.Errorf("%s: held=%v want %v", c.name, got, c.want)
		}
	}
	// the door opens nothing else: with no human the locked doc and its root
	// item still read as 0 rows in the tenant scope (rdb 0256 unchanged)
	var docs, items int
	if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM workspace_doc WHERE restricted_to_human IS NOT NULL`).Scan(&docs); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `SELECT count(*) FROM workspace_doc_item WHERE id = $1`, rootLock).Scan(&items)
	}); err != nil {
		t.Fatal(err)
	}
	if docs != 0 || items != 0 {
		t.Errorf("no human: locked docs=%d, its root items=%d visible, want 0 and 0", docs, items)
	}
}

// TestDocAssetHeldDoorCatalogue pins rdb 0307's door: one
// spool_doc_asset_held(text) returning a boolean only, SECURITY DEFINER,
// LANGUAGE sql, no tenant parameter, owned by a NOLOGIN NOBYPASSRLS role the
// connected login does not inherit, EXECUTE not granted to PUBLIC, and the
// role holding no write grant on any table.
func TestDocAssetHeldDoorCatalogue(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	ctx := context.Background()
	for _, c := range []struct{ name, sql string }{
		{"one boolean definer, no tenant parameter", `SELECT count(*) = 1 AND bool_and(p.prosecdef AND p.prorettype = 'boolean'::regtype
				AND NOT p.proretset AND l.lanname = 'sql' AND p.pronargs = 1
				AND array_to_string(p.proargnames, ',') NOT ILIKE '%tenant%'
				AND pg_get_userbyid(p.proowner) = 'spool_doc_asset_reader')
			FROM pg_proc p JOIN pg_language l ON l.oid = p.prolang WHERE p.proname = 'spool_doc_asset_held'`},
		{"owner NOLOGIN NOBYPASSRLS, not inherited by this login", `SELECT NOT r.rolcanlogin AND NOT r.rolbypassrls AND NOT r.rolsuper
				AND NOT pg_has_role(current_user, r.oid, 'USAGE')
			FROM pg_roles r WHERE r.rolname = 'spool_doc_asset_reader'`},
		{"PUBLIC has no EXECUTE", `SELECT NOT EXISTS (SELECT 1 FROM pg_proc p, aclexplode(p.proacl) a
				WHERE p.proname = 'spool_doc_asset_held' AND a.grantee = 0)`},
		{"no write grant", `SELECT NOT EXISTS (SELECT 1 FROM information_schema.role_table_grants
				WHERE grantee = 'spool_doc_asset_reader' AND privilege_type <> 'SELECT')
			AND NOT EXISTS (SELECT 1 FROM information_schema.column_privileges
				WHERE grantee = 'spool_doc_asset_reader' AND privilege_type <> 'SELECT')`},
	} {
		var okc bool
		if err := pg.Pool().QueryRow(ctx, c.sql).Scan(&okc); err != nil {
			t.Fatalf("%s: %v", c.name, err)
		}
		if !okc {
			t.Errorf("rdb 0307 door: %s does not hold", c.name)
		}
	}
}

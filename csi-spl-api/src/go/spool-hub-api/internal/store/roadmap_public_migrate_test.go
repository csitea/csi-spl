package store

import (
	"context"
	"testing"
)

// rdb 0162 (specs/112 RDB-2, spec 12.5, OQ3): tenants.roadmap_public, a
// workspace roadmap is internal until its workspace turns it public.
// Postgres only: the column is the migration under test.
//
// Pair, n=2 workspaces on one fresh database:
//   - control: a fresh tenant row reads roadmap_public = false (a DEFAULT
//     true in 0162 turns this red).
//   - flip: a's own scope sets it true, b's row stays false and a's scope
//     cannot write b's (tenants FORCE RLS, 0021).
func TestTenantRoadmapPublic0162(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	read := func(tenant string) bool {
		t.Helper()
		var on bool
		if err := pg.queryRowTenant(ctx, tenant, `SELECT roadmap_public FROM tenants WHERE tenant_id = $1`,
			[]any{tenant}, &on); err != nil {
			t.Fatal(err)
		}
		return on
	}
	for _, id := range []string{a, b} {
		if read(id) {
			t.Fatalf("CONTROL: fresh workspace %s reads roadmap_public = true, want false (OQ3)", id)
		}
	}
	if _, err := pg.execTenant(ctx, a, `UPDATE tenants SET roadmap_public = true WHERE tenant_id = $1`, a); err != nil {
		t.Fatal(err)
	}
	tag, err := pg.execTenant(ctx, a, `UPDATE tenants SET roadmap_public = true WHERE tenant_id = $1`, b)
	if err != nil {
		t.Fatal(err)
	}
	if !read(a) || read(b) || tag.RowsAffected() != 0 {
		t.Fatalf("a=%v b=%v cross rows=%d, want a on, b off, 0", read(a), read(b), tag.RowsAffected())
	}
}

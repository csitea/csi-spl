package store

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"
)

// Spec 108 section 4, pair (a), n=1: workspace isolation in the store.
// Workspace A holds one message. The same query, with NO tenant_id
// predicate (so only row level security stands between the workspaces),
// runs under workspace B's tenant_id and must read 0 rows of it; the
// CONTROL runs it under A's tenant_id and must read the row, so a 0 for B
// means "not visible to B", not "not there". Postgres only (rlsStore):
// hub-pg.tst.sh runs it as a non-superuser owner role, where RLS binds.

// TestIsolationPairWorkspaceBReadsNoneOfA is pair (a), n=1.
func TestIsolationPairWorkspaceBReadsNoneOfA(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, msgA := rlsTenant(t, pg)
	b := newTenant(t, pg)

	// count reads A's message and its delivery under one workspace's scope,
	// with no tenant predicate of its own: the scope (inTenant) is the only
	// guard.
	count := func(tenant string) (msgs, dels int) {
		t.Helper()
		if err := pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM messages WHERE msg_id = $1`, msgA).Scan(&msgs); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT count(*) FROM deliveries WHERE msg_id = $1`, msgA).Scan(&dels)
		}); err != nil {
			t.Fatal(err)
		}
		return msgs, dels
	}

	// CONTROL: under A's tenant_id the message and its delivery are there.
	if m, d := count(a); m != 1 || d != 1 {
		t.Fatalf("control: workspace A reads %d message / %d delivery row(s) of its own %s, want 1 / 1", m, d, msgA)
	}
	// PAIR: under B's tenant_id the same query reads none of them.
	if m, d := count(b); m != 0 || d != 0 {
		t.Fatalf("workspace B (%s) reads %d message / %d delivery row(s) of workspace A's %s, want 0 / 0", b, m, d, msgA)
	}
}

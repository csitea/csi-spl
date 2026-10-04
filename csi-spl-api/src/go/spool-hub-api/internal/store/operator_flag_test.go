package store

import (
	"context"
	"testing"

	"github.com/jackc/pgx/v5"
)

// clearOperatorFlag unflags every workspace, so the shared test database
// leaves the operator workspace to the cnf again for the next test.
func clearOperatorFlag(t *testing.T, st Store) {
	t.Helper()
	switch s := st.(type) {
	case *Memory:
		s.mu.Lock()
		s.operatorTenant = ""
		s.mu.Unlock()
	case *Postgres:
		if _, err := s.pool.Exec(context.Background(), `BEGIN; SELECT set_config('app.rls_scope', 'operator', true);
			UPDATE tenants SET is_operator = false WHERE is_operator; COMMIT`); err != nil {
			t.Fatal(err)
		}
		s.opCache.forget()
	}
}

// TestOperatorFlagClaim (rdb 0116, spec 074 phase 1b): the first claim flags
// its workspace, and a later claim of ANOTHER workspace does not move the
// flag (the database is the authority once set). CONTROL: before any claim
// no workspace is flagged, and a claim of a workspace that does not exist
// flags nothing - so the "a" read after is the claim, not a leftover.
func TestOperatorFlagClaim(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := st.(OperatorFlag)
			clearOperatorFlag(t, st)
			t.Cleanup(func() { clearOperatorFlag(t, st) })
			if id, err := f.OperatorTenant(ctx); err != nil || id != "" {
				t.Fatalf("before any claim: %q %v, want none", id, err)
			}
			if id, err := f.ClaimOperatorTenant(ctx, uid("t")); err != nil || id != "" {
				t.Fatalf("claim of a missing workspace: %q %v, want none", id, err)
			}
			a, b := newTenant(t, st), newTenant(t, st)
			if id, err := f.ClaimOperatorTenant(ctx, a); err != nil || id != a {
				t.Fatalf("first claim: %q %v, want %q", id, err, a)
			}
			if id, err := f.ClaimOperatorTenant(ctx, b); err != nil || id != a {
				t.Fatalf("second claim moved the flag: %q %v, want %q", id, err, a)
			}
			if id, err := f.OperatorTenant(ctx); err != nil || id != a {
				t.Fatalf("read: %q %v, want %q", id, err, a)
			}
		})
	}
}

// TestOperatorFlagUnique (Postgres only): tenants_operator_unique refuses a
// second flagged workspace even when written past the store. CONTROL: the
// same UPDATE on the already-flagged row succeeds.
func TestOperatorFlagUnique(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	clearOperatorFlag(t, pg)
	t.Cleanup(func() { clearOperatorFlag(t, pg) })
	a, b := newTenant(t, pg), newTenant(t, pg)
	if _, err := pg.ClaimOperatorTenant(ctx, a); err != nil {
		t.Fatal(err)
	}
	set := func(id string) error {
		return pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `SELECT set_config('app.rls_scope', 'operator', true)`); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `UPDATE tenants SET is_operator = true WHERE tenant_id = $1`, id)
			return err
		})
	}
	if err := set(a); err != nil {
		t.Fatalf("control: re-flagging the operator workspace: %v", err)
	}
	if err := set(b); err == nil {
		t.Fatal("a second operator workspace was accepted")
	}
}

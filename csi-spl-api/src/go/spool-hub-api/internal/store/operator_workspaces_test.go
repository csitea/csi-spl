package store

import (
	"context"
	"errors"
	"testing"
)

// TestFleetSeatingSwitch (spec 158 T5, rdb 0230): a workspace starts with
// fleet_seating false (the column default; the create ROUTE sets it), the
// switch writes true and back to false, and a missing workspace is
// ErrNotFound on both calls. On Postgres it runs in the tenant scope as the
// test role, which must not bypass RLS (printed). CONTROL: the second
// workspace keeps false while the first flips, so the read is per workspace.
func TestFleetSeatingSwitch(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			if pg, ok := st.(*Postgres); ok {
				var who string
				var super, bypass bool
				if err := pg.pool.QueryRow(ctx, `SELECT rolname, rolsuper, rolbypassrls FROM pg_roles
					WHERE rolname = current_user`).Scan(&who, &super, &bypass); err != nil {
					t.Fatal(err)
				}
				t.Logf("postgres role %s rolsuper=%v rolbypassrls=%v", who, super, bypass)
			}
			fs := st.(FleetSeating)
			a, b := newTenant(t, st), newTenant(t, st)
			if on, err := fs.FleetSeating(ctx, a); err != nil || on {
				t.Fatalf("new workspace reads %v %v, want the default false", on, err)
			}
			for _, want := range []bool{true, false, true} {
				if err := fs.SetFleetSeating(ctx, a, want); err != nil {
					t.Fatalf("set %v: %v", want, err)
				}
				if on, err := fs.FleetSeating(ctx, a); err != nil || on != want {
					t.Fatalf("read after set %v: %v %v", want, on, err)
				}
				if on, err := fs.FleetSeating(ctx, b); err != nil || on {
					t.Fatalf("CONTROL: untouched workspace reads %v %v, want false", on, err)
				}
			}
			missing := uid("t-")
			if _, err := fs.FleetSeating(ctx, missing); !errors.Is(err, ErrNotFound) {
				t.Fatalf("read of a missing workspace: %v, want ErrNotFound", err)
			}
			if err := fs.SetFleetSeating(ctx, missing, true); !errors.Is(err, ErrNotFound) {
				t.Fatalf("write of a missing workspace: %v, want ErrNotFound", err)
			}
		})
	}
}

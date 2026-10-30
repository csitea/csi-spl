package store

import (
	"context"
	"testing"
)

// TestCreateTenantFleetSeating (spec 158 T5, SPL-4295): every workspace
// create sets fleet_seating true unless told false. CreateTenant is the one
// insert every create path shares: the operator route, `spool hub-tenant`
// (do_spl_tenant_create, which made a prd workspace on 2026-10-29 with the switch
// off) and the auth demo. RED on master before the fix: the INSERT left the
// column at its rdb 0230 default false. CONTROL: FleetSeatingOff creates it
// off, so the read is not a constant true.
func TestCreateTenantFleetSeating(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fs := st.(FleetSeating)
			id := newTenant(t, st)
			if on, err := fs.FleetSeating(ctx, id); err != nil || !on {
				t.Fatalf("CreateTenant with no fleet seating field: %s reads %v %v, want true", id, on, err)
			}
			off := uid("t-")
			if err := st.CreateTenant(ctx, Tenant{ID: off, RootPubKey: pubkey(), FleetSeatingOff: true}); err != nil {
				t.Fatal(err)
			}
			if on, err := fs.FleetSeating(ctx, off); err != nil || on {
				t.Fatalf("CONTROL: CreateTenant with FleetSeatingOff: %s reads %v %v, want false", off, on, err)
			}
		})
	}
}

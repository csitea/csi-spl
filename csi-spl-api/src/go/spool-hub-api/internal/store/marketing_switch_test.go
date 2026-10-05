package store

import (
	"context"
	"errors"
	"testing"
)

// TestMarketingSwitch (spec 090 §15): a workspace starts off, its switch
// turns it on and off again, and one workspace's switch leaves another's
// alone. Runs on the memory store, and on Postgres when SPOOL_TEST_PG_DSN
// is set (rdb 0129 under FORCE RLS).
func TestMarketingSwitch(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			ms := st.(MarketingSwitch)
			a, b := uid("t-"), uid("t-")
			for _, id := range []string{a, b} {
				if err := st.CreateTenant(ctx, Tenant{ID: id, RootPubKey: pubkey()}); err != nil {
					t.Fatal(err)
				}
			}
			if on, err := ms.MarketingEnabled(ctx, a); err != nil || on {
				t.Fatalf("CONTROL: fresh workspace: on=%v err=%v, want off", on, err)
			}
			if err := ms.SetMarketingEnabled(ctx, a, true); err != nil {
				t.Fatal(err)
			}
			if on, _ := ms.MarketingEnabled(ctx, a); !on {
				t.Fatal("not on after the admin turned it on")
			}
			if on, _ := ms.MarketingEnabled(ctx, b); on {
				t.Fatal("turning a on turned b on")
			}
			if err := ms.SetMarketingEnabled(ctx, a, false); err != nil {
				t.Fatal(err)
			}
			if on, _ := ms.MarketingEnabled(ctx, a); on {
				t.Fatal("CONTROL: still on after the admin turned it off")
			}
			if _, err := ms.MarketingEnabled(ctx, "t-none"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("no tenant read: %v, want ErrNotFound", err)
			}
			if err := ms.SetMarketingEnabled(ctx, "t-none", false); !errors.Is(err, ErrNotFound) {
				t.Fatalf("no tenant write: %v, want ErrNotFound", err)
			}
		})
	}
}

// TestMarketingSwitchRLS (rdb 0129): the flag rides tenants' FORCE RLS, so
// one workspace's scope cannot flip another workspace's switch.
func TestMarketingSwitchRLS(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := uid("t-"), uid("t-")
	for _, id := range []string{a, b} {
		if err := pg.CreateTenant(ctx, Tenant{ID: id, RootPubKey: pubkey()}); err != nil {
			t.Fatal(err)
		}
	}
	tag, err := pg.execTenant(ctx, a, `UPDATE tenants SET marketing_enabled = true WHERE tenant_id = $1`, b)
	if err != nil {
		t.Fatal(err)
	}
	if tag.RowsAffected() != 0 {
		t.Fatalf("CONTROL: workspace %s turned on %s's marketing (%d rows)", a, b, tag.RowsAffected())
	}
	if on, _ := pg.MarketingEnabled(ctx, b); on {
		t.Fatal("b is on after a cross-workspace write")
	}
}

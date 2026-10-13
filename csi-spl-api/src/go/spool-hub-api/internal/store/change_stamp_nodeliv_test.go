package store

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// The deliveries-free stamp (rdb 0190, perf round 5 P5-10). Postgres only.
// GET /v1/view/channels gates on it, so it must move on every covered write
// but a deliveries one, and a deliveries write must leave it settled.

func stampBoth(t *testing.T, pg *Postgres, tenant string) ChangeStamp {
	t.Helper()
	now := time.Now()
	c, err := pg.ChangeStamp(context.Background(), tenant, now, now)
	if err != nil {
		t.Fatal(err)
	}
	return c
}

// TestChangeStampNoDeliveriesEveryTable: a write to a covered table moves
// both stamps, except deliveries, which moves the 0103 stamp alone.
func TestChangeStampNoDeliveriesEveryTable(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := seedTenantAll(t, pg)
	for _, tb := range stampTables {
		t.Run(tb, func(t *testing.T) {
			before := stampBoth(t, pg, a.tenant)
			if err := pg.inTenant(ctx, a.tenant, func(tx pgx.Tx) error {
				tag, err := tx.Exec(ctx, `UPDATE `+pgx.Identifier{tb}.Sanitize()+` SET tenant_id = tenant_id WHERE tenant_id = $1`, a.tenant)
				if err == nil && tag.RowsAffected() == 0 {
					t.Fatalf("seedTenantAll wrote no %s row (control)", tb)
				}
				return err
			}); err != nil {
				t.Fatal(err)
			}
			after := stampBoth(t, pg, a.tenant)
			if after.Stamp <= before.Stamp {
				t.Fatalf("%s: the 0103 stamp stayed at %d", tb, after.Stamp)
			}
			moved := after.NoDeliveries > before.NoDeliveries
			if tb == "deliveries" && moved {
				t.Errorf("a deliveries write moved the no-deliveries stamp %d -> %d", before.NoDeliveries, after.NoDeliveries)
			}
			if tb != "deliveries" && !moved {
				t.Errorf("a %s write left the no-deliveries stamp at %d: a channels 304 would be stale", tb, after.NoDeliveries)
			}
		})
	}
	t.Run("global rbac", func(t *testing.T) {
		before := stampBoth(t, pg, a.tenant)
		if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE rbac_permissions SET description = description WHERE permission_id = 'threads.read'`)
			return err
		}); err != nil {
			t.Fatal(err)
		}
		if after := stampBoth(t, pg, a.tenant); after.NoDeliveries <= before.NoDeliveries {
			t.Errorf("an rbac_permissions write left the no-deliveries stamp at %d", after.NoDeliveries)
		}
	})
}

// TestChangeStampNoDeliveriesOrderAndSettle: in one transaction a
// deliveries row before a messages row still moves the no-deliveries stamp
// (the per-transaction marks are kept apart), and a deliveries-only commit
// unsettles the 0103 stamp but not the no-deliveries one.
func TestChangeStampNoDeliveriesOrderAndSettle(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := seedTenantAll(t, pg)
	touch := func(tables ...string) {
		t.Helper()
		if err := pg.inTenant(ctx, a.tenant, func(tx pgx.Tx) error {
			for _, tb := range tables {
				if _, err := tx.Exec(ctx, `UPDATE `+pgx.Identifier{tb}.Sanitize()+` SET tenant_id = tenant_id WHERE tenant_id = $1`, a.tenant); err != nil {
					return err
				}
			}
			return nil
		}); err != nil {
			t.Fatal(err)
		}
	}
	before := stampBoth(t, pg, a.tenant)
	touch("deliveries", "messages")
	if after := stampBoth(t, pg, a.tenant); after.NoDeliveries <= before.NoDeliveries {
		t.Fatalf("deliveries then messages in one transaction left the no-deliveries stamp at %d", after.NoDeliveries)
	}
	// Age every change past ChangeStampSettle (the operator scope).
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `UPDATE tenant_change_stamps SET changed_at = changed_at - interval '1 minute',
			nodeliv_changed_at = nodeliv_changed_at - interval '1 minute' WHERE tenant_id = $1`, a.tenant)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	if c := stampBoth(t, pg, a.tenant); !c.Settled || !c.NoDeliveriesSettled {
		t.Fatalf("aged: settled %v / %v, want both (control)", c.Settled, c.NoDeliveriesSettled)
	}
	before = stampBoth(t, pg, a.tenant)
	touch("deliveries")
	c := stampBoth(t, pg, a.tenant)
	if c.Settled || !c.NoDeliveriesSettled || c.NoDeliveries != before.NoDeliveries {
		t.Fatalf("after a deliveries write: settled %v, no-deliveries settled %v, %d -> %d; want false, true, unchanged",
			c.Settled, c.NoDeliveriesSettled, before.NoDeliveries, c.NoDeliveries)
	}
	touch("messages")
	if c := stampBoth(t, pg, a.tenant); c.NoDeliveriesSettled || c.NoDeliveries <= before.NoDeliveries {
		t.Fatalf("after a messages write: no-deliveries settled %v at %d, want unsettled and moved", c.NoDeliveriesSettled, c.NoDeliveries)
	}
}

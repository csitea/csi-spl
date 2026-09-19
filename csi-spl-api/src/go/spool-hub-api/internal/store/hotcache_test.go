package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
)

// TestHotCacheRaceGuard: a fill that read its row before a write must not
// store it after that write (the gen check), or a revoked pin would be served
// for a whole TTL.
func TestHotCacheRaceGuard(t *testing.T) {
	var c hotCache
	gen := c.generation() // a GetPin read starts
	c.forget()            // a RevokePin commits meanwhile
	c.putPin(gen, "t1", "box-a", pubkey())
	if _, ok := c.pin("t1", "box-a"); ok {
		t.Fatal("a fill older than a write was cached")
	}
	c.putPin(c.generation(), "t1", "box-a", pubkey())
	if _, ok := c.pin("t1", "box-a"); !ok {
		t.Fatal("CONTROL: a current fill was not cached")
	}
	if _, ok := c.pin("t2", "box-a"); ok {
		t.Fatal("tenant t1's pin answered for t2")
	}
}

// TestHotCacheStalenessBound (027 T040, the bound the spec states): a write
// this process did not make - here SQL run beside the store - is served stale
// for at most hotCacheTTL, then read fresh. A miss is never cached.
func TestHotCacheStalenessBound(t *testing.T) {
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("SPOOL_TEST_PG_DSN unset")
	}
	now := time.Now()
	hotNow = func() time.Time { return now }
	t.Cleanup(func() { hotNow = time.Now })
	ctx := context.Background()
	tid := newTenant(t, pg)

	if _, err := pg.GetPin(ctx, tid, "box-a"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("unpinned: %v", err)
	}
	pub := pubkey()
	if err := pg.PutPin(ctx, tid, "box-a", pub, false, now, now); err != nil {
		t.Fatal(err)
	}
	if got, err := pg.GetPin(ctx, tid, "box-a"); err != nil || !got.Equal(pub) {
		t.Fatalf("a miss was cached: %v", err)
	}
	if tn, err := pg.GetTenant(ctx, tid); err != nil || tn.BillingStatus != billing.StatusInternal {
		t.Fatalf("tenant: %+v %v", tn, err)
	}

	// Out-of-band: revoke and unpaid by SQL, not through this store.
	if err := pg.inTenant(ctx, tid, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE pins SET revoked_at = now() WHERE tenant_id = $1`, tid); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE tenants SET billing_status = 'unpaid' WHERE tenant_id = $1`, tid)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	now = now.Add(hotCacheTTL - time.Millisecond)
	if _, err := pg.GetPin(ctx, tid, "box-a"); err != nil {
		t.Fatalf("within the TTL the cached pin is served (this is the bound): %v", err)
	}
	now = now.Add(time.Millisecond)
	if _, err := pg.GetPin(ctx, tid, "box-a"); !errors.Is(err, ErrNotFound) {
		t.Fatalf("at the TTL an out-of-band revoke must be seen: %v", err)
	}
	if tn, _ := pg.GetTenant(ctx, tid); tn.BillingStatus != billing.StatusUnpaid {
		t.Fatalf("at the TTL an out-of-band unpaid must be seen: %q", tn.BillingStatus)
	}
}

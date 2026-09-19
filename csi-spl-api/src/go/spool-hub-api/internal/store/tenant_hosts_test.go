package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// TestTenantHostQueue (specs/024 FR-002): every created tenant reads a
// pending host until the reconcile marks it; an unknown tenant has none.
func TestTenantHostQueue(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			if _, err := st.TenantHost(ctx, uid("t-")); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown tenant: want ErrNotFound, got %v", err)
			}
			tid := newTenant(t, st)
			h, err := st.TenantHost(ctx, tid)
			if err != nil || h.Status != HostPending {
				t.Fatalf("new tenant: want pending, got %+v %v", h, err)
			}
			if err := st.SetTenantHost(ctx, tid, HostReady, "", now); err != nil {
				t.Fatal(err)
			}
			if h, _ := st.TenantHost(ctx, tid); h.Status != HostReady {
				t.Fatalf("after ready: %+v", h)
			}
			if err := st.SetTenantHost(ctx, tid, "bogus", "", now); err == nil {
				t.Fatal("a bogus status was accepted")
			}
			// the paid transition queues the host too (trigger on tenants)
			paid := uid("t")
			c := testCheckout(t, paid)
			if err := st.HoldCheckout(ctx, c, now, time.Hour); err != nil {
				t.Fatal(err)
			}
			if _, err := st.TenantHost(ctx, paid); !errors.Is(err, ErrNotFound) {
				t.Fatalf("a held slug must not queue a host: %v", err)
			}
			ev := PaymentEvent{Provider: "fake", EventID: "ev-" + c.ID, CheckoutID: c.ID, Kind: PayEventPaid}
			if out, err := st.ApplyPayment(ctx, ev, now); err != nil || out != PayOutcomePaid {
				t.Fatalf("paid: %q %v", out, err)
			}
			if h, err := st.TenantHost(ctx, paid); err != nil || h.Status != HostPending {
				t.Fatalf("paid tenant: want pending, got %+v %v", h, err)
			}
		})
	}
}

// TestTenantHostTriggers (Postgres only): a deleted tenant marks its host
// removing (the row outlives it), a re-created slug queues it again, and a
// ready host of an existing tenant is not reset by a no-op re-insert.
func TestTenantHostTriggers(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	now := time.Now().UTC()
	tid := newTenant(t, pg)
	if err := pg.SetTenantHost(ctx, tid, HostReady, "", now); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.pool.Exec(ctx, `BEGIN; SELECT set_config('app.rls_scope', 'operator', true);
		DELETE FROM tenants WHERE tenant_id = '`+tid+`'; COMMIT`); err != nil {
		t.Fatal(err)
	}
	if h, err := pg.TenantHost(ctx, tid); err != nil || h.Status != HostRemoving {
		t.Fatalf("deleted tenant: want removing, got %+v %v", h, err)
	}
	if err := pg.CreateTenant(ctx, Tenant{ID: tid, RootPubKey: pubkey()}); err != nil {
		t.Fatal(err)
	}
	if h, _ := pg.TenantHost(ctx, tid); h.Status != HostPending {
		t.Fatalf("re-created tenant: want pending, got %+v", h)
	}
	if err := pg.SetTenantHost(ctx, tid, HostReady, "", now); err != nil {
		t.Fatal(err)
	}
	ten, _ := pg.GetTenant(ctx, tid)
	if err := pg.CreateTenant(ctx, ten); err != nil { // idempotent no-op insert
		t.Fatal(err)
	}
	if h, _ := pg.TenantHost(ctx, tid); h.Status != HostReady {
		t.Fatalf("no-op re-insert reset a ready host: %+v", h)
	}
}

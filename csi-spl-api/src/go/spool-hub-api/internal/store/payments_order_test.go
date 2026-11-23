package store

import (
	"context"
	"crypto/rand"
	"encoding/base32"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
)

// Spec 181 row B2 (rdb 0314, Q-18 C): the private-workspace order submit on
// both drivers. Done test: a submit -> one tenant, one order,
// box_join_enabled true, the seat caps, the private_vm plan and the buyer
// signing in as biz_owner. RED CONTROL: the submit replayed -> one tenant
// and one order, not two (the replay answers the first order).

// testOrderID is a fresh order id of rdb 0314's shape (unique per row).
func testOrderID() string {
	b := make([]byte, 16)
	_, _ = rand.Read(b)
	return "wo_" + strings.ToLower(base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(b))
}

// testOrder is a synthetic order for tenant (no real person or address).
func testOrder(tenant string) WorkspaceOrder {
	return WorkspaceOrder{ID: testOrderID(), TenantID: tenant, SeatsUsers: 3,
		Email: "Buyer-" + tenant + "@Example.com", RootPubKey: pubkey(),
		Billing: BillingDetails{Name: "FirstName LastName Oy", Address: "1 Example Street, 00100 City", Country: "fi"}}
}

// seedWorkspaceOrder writes one rdb 0314 row for an existing tenant under
// inTenant (crosstenant_test.go): the store API makes its own tenant.
func seedWorkspaceOrder(ctx context.Context, pg *Postgres, tenant string) error {
	return pg.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO workspace_orders (order_id, tenant_id, seats_users, email,
			billing_name, billing_address, billing_country) VALUES ($1, $2, 1, 'buyer@example.com',
			'FirstName LastName', '1 Example Street', 'FI')`, testOrderID(), tenant)
		return err
	})
}

func TestWorkspaceOrderSubmit(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tenant := uid("t")
			o := testOrder(tenant)
			got, created, err := st.SubmitWorkspaceOrder(ctx, o, now)
			if err != nil || !created || got.ID != o.ID || got.Status != OrderSubmitted || got.Billing.Country != "FI" {
				t.Fatalf("submit: %+v created=%v %v", got, created, err)
			}
			tn, err := st.GetTenant(ctx, tenant)
			if err != nil || tn.BillingStatus != billing.StatusActive || tn.PlanID != PlanKindPrivateVM || tn.SeatsUsers != 3 || tn.SeatsBots != 0 {
				t.Fatalf("tenant: %+v %v", tn, err)
			}
			if on, err := st.(BoxJoinSwitch).BoxJoinEnabled(ctx, tenant); err != nil || !on {
				t.Fatalf("box_join_enabled = %v %v, want true", on, err)
			}
			if p, err := st.(PricePlans).PricePlan(ctx, tenant); err != nil || !reflect.DeepEqual(p, PrivateVMPlan()) {
				t.Fatalf("price plan: %+v %v, want PrivateVMPlan", p, err)
			}
			if back, err := st.WorkspaceOrder(ctx, tenant); err != nil || back.ID != o.ID || back.Email != got.Email {
				t.Fatalf("order read: %+v %v", back, err)
			}
			h := st.(Humans)
			buyer := Identity{Provider: "google", Subject: uid("s-"), Email: o.Email}
			hum, err := h.Admit(ctx, buyer, tenant, AdmitPolicy{}, now.Add(time.Minute))
			if err != nil {
				t.Fatalf("buyer admit: %v", err)
			}
			if r, err := h.MemberRole(ctx, hum, tenant); err != nil || r != RoleTenantOwner {
				t.Fatalf("buyer role = %q %v, want %q", r, err, RoleTenantOwner)
			}
		})
	}
}

// RED CONTROL: the same order submitted again (a new id and a new placeholder
// key, as a resent form makes) answers the first order and writes nothing.
func TestWorkspaceOrderReplayIsOneTenantOneOrder(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tenant := uid("t")
			first, created, err := st.SubmitWorkspaceOrder(ctx, testOrder(tenant), now)
			if err != nil || !created {
				t.Fatalf("first: %v %v", created, err)
			}
			again := testOrder(tenant)
			again.ID, again.RootPubKey = testOrderID(), pubkey()
			got, created, err := st.SubmitWorkspaceOrder(ctx, again, now.Add(time.Second))
			if err != nil || created || got.ID != first.ID {
				t.Fatalf("replay: id %q created=%v %v, want the first order %q, not a second", got.ID, created, err, first.ID)
			}
			tn, err := st.GetTenant(ctx, tenant)
			if err != nil || !tn.RootPubKey.Equal(first.RootPubKey) {
				t.Fatalf("the replay re-keyed or remade the tenant: %v", err)
			}
			if pg, ok := st.(*Postgres); ok {
				for _, tb := range []string{"tenants", "workspace_orders", "price_plans"} {
					if n := countOf(t, pg, tb, tenant); n != 1 {
						t.Errorf("%s rows for the tenant = %d, want 1", tb, n)
					}
				}
			}
		})
	}
}

// A slug that is already a workspace, or an order by another email, is a
// conflict; nothing of the order is written.
func TestWorkspaceOrderConflicts(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			taken := newTenant(t, st)
			if _, _, err := st.SubmitWorkspaceOrder(ctx, testOrder(taken), now); !errors.Is(err, ErrConflict) {
				t.Fatalf("an existing tenant: %v, want ErrConflict", err)
			}
			if _, err := st.WorkspaceOrder(ctx, taken); !errors.Is(err, ErrNotFound) {
				t.Fatalf("an order was written for the existing tenant: %v", err)
			}
			if on, _ := st.(BoxJoinSwitch).BoxJoinEnabled(ctx, taken); on {
				t.Fatal("box_join_enabled turned on for the existing tenant")
			}
			tenant := uid("t")
			if _, _, err := st.SubmitWorkspaceOrder(ctx, testOrder(tenant), now); err != nil {
				t.Fatal(err)
			}
			other := testOrder(tenant)
			other.Email = "someone-else@example.com"
			if _, _, err := st.SubmitWorkspaceOrder(ctx, other, now); !errors.Is(err, ErrConflict) {
				t.Fatalf("another email on the slug: %v, want ErrConflict", err)
			}
		})
	}
}

func TestWorkspaceOrderInputRefused(t *testing.T) {
	ctx := context.Background()
	st := NewMemory()
	for name, mut := range map[string]func(*WorkspaceOrder){
		"no seats":         func(o *WorkspaceOrder) { o.SeatsUsers = 0 },
		"no billing name":  func(o *WorkspaceOrder) { o.Billing.Name = " " },
		"no address":       func(o *WorkspaceOrder) { o.Billing.Address = "" },
		"bad country":      func(o *WorkspaceOrder) { o.Billing.Country = "FIN" },
		"bad email":        func(o *WorkspaceOrder) { o.Email = "nobody" },
		"bad order id":     func(o *WorkspaceOrder) { o.ID = "co_abc" },
		"short root key":   func(o *WorkspaceOrder) { o.RootPubKey = o.RootPubKey[:8] },
		"unsupported lang": func(o *WorkspaceOrder) { o.Locale = "xx" },
	} {
		tenant := uid("t")
		o := testOrder(tenant)
		mut(&o)
		if _, _, err := st.SubmitWorkspaceOrder(ctx, o, time.Now()); err == nil {
			t.Errorf("%s: stored, want a refusal", name)
		}
		if _, err := st.GetTenant(ctx, tenant); !errors.Is(err, ErrNotFound) {
			t.Errorf("%s: a refused order made its tenant", name)
		}
	}
}

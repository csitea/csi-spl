package store

import (
	"context"
	"testing"
	"time"
)

// Spec 181 row B14 (gap G15): the issuer's read on both drivers. Two private
// workspaces and one that is not: the list holds the two, each with the
// count CountMembers answers; one named workspace answers itself, a
// non-private one answers none.

// admitHumans admits n humans to tenant: a bootstrap owner, then invited
// members.
func admitHumans(t *testing.T, s Store, tenant string, n int) {
	t.Helper()
	ctx, now := context.Background(), time.Now().UTC()
	h := s.(Humans)
	boot := AdmitPolicy{BootstrapOwner: true}
	owner, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("o-"), Email: "owner@example.com"}, tenant, boot, now)
	if err != nil {
		t.Fatal(err)
	}
	for i := 1; i < n; i++ {
		email := uid("m-") + "@example.com"
		if err := h.PutInvite(ctx, Invite{TenantID: tenant, Email: email, InvitedBy: owner, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
			t.Fatal(err)
		}
		if _, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("s-"), Email: email}, tenant, boot, now); err != nil {
			t.Fatal(err)
		}
	}
}

// privateOf keeps the named workspaces (other tests' workspaces share the
// Postgres database).
func privateOf(t *testing.T, s Store, tenant string, keep ...string) map[string]int64 {
	t.Helper()
	got, err := s.(PrivateWorkspaces).PrivateWorkspaceMembers(context.Background(), tenant)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]int64{}
	for _, w := range got {
		for _, k := range keep {
			if w.Tenant == k {
				out[w.Tenant] = w.Humans
			}
		}
	}
	return out
}

func TestPrivateWorkspaceMembers(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			a, b, plain := newTenant(t, s), newTenant(t, s), newTenant(t, s)
			for _, id := range []string{a, b} {
				if err := s.(PricePlans).PutPricePlan(ctx, id, PrivateVMPlan()); err != nil {
					t.Fatal(err)
				}
			}
			admitHumans(t, s, a, 3)
			admitHumans(t, s, b, 1)
			admitHumans(t, s, plain, 2)
			got := privateOf(t, s, "", a, b, plain)
			if len(got) != 2 || got[a] != 3 || got[b] != 1 {
				t.Fatalf("private workspaces = %v, want %s:3 %s:1 and not %s", got, a, b, plain)
			}
			for _, id := range []string{a, b} {
				n, err := s.CountMembers(ctx, id)
				if err != nil || int64(n) != got[id] {
					t.Fatalf("%s: list says %d, CountMembers %d %v", id, got[id], n, err)
				}
			}
			if one := privateOf(t, s, a, a, b); len(one) != 1 || one[a] != 3 {
				t.Fatalf("one named = %v, want only %s:3", one, a)
			}
			if none := privateOf(t, s, plain, plain); len(none) != 0 {
				t.Fatalf("a workspace off the plan = %v, want none", none)
			}
		})
	}
}

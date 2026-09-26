package store

import (
	"context"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// TestMembershipsInTenantSortOrder (rdb 0051, SPL-71): a human's memberships
// come back in the tenants' sort_order, 1 first, whatever the tenant ids
// sort as; tenants with no sort_order follow, by tenant id. The WUI drop box
// draws them in this order.
func TestMembershipsInTenantSortOrder(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			base := uid("so")
			// Ids sort a..e; the wanted order is not that.
			ids := []string{base + "-a", base + "-b", base + "-c", base + "-d", base + "-e"}
			order := map[string]int{ids[3]: 1, ids[1]: 2, ids[4]: 3}
			for _, id := range ids {
				if err := s.CreateTenant(ctx, Tenant{ID: id, RootPubKey: pubkey(), SortOrder: order[id]}); err != nil {
					t.Fatal(err)
				}
				if pg, ok := s.(*Postgres); ok && order[id] > 0 {
					if err := pgx.BeginFunc(ctx, pg.Pool(), func(tx pgx.Tx) error {
						if _, err := tx.Exec(ctx, pgScopeOperator); err != nil {
							return err
						}
						_, err := tx.Exec(ctx, `UPDATE tenants SET sort_order = $2 WHERE tenant_id = $1`, id, order[id])
						return err
					}); err != nil {
						t.Fatal(err)
					}
				}
			}
			var h Humans = s.(Humans)
			now := time.Now().UTC()
			who := Identity{Provider: "google", Subject: uid("sub-"), Email: base + "@example.com", Name: "A"}
			var human string
			for _, id := range ids {
				got, err := h.Admit(ctx, who, id, AdmitPolicy{BootstrapOwner: true}, now)
				if err != nil {
					t.Fatal(err)
				}
				human = got
			}
			ms, err := s.(MembershipLister).Memberships(ctx, human)
			if err != nil {
				t.Fatal(err)
			}
			var got []string
			for _, m := range ms {
				got = append(got, m.TenantID)
			}
			want := []string{ids[3], ids[1], ids[4], ids[0], ids[2]}
			if len(got) != len(want) {
				t.Fatalf("memberships %v, want %v", got, want)
			}
			for i := range want {
				if got[i] != want[i] {
					t.Fatalf("memberships %v, want %v", got, want)
				}
			}
		})
	}
}

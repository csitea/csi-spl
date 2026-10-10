package store

import (
	"context"
	"errors"
	"testing"

	"github.com/jackc/pgx/v5"
)

// seedEmbedCustomer writes one embed of tenant (owner store, tenant scope)
// and returns its id. The embed admin API that writes these is T203's.
func seedEmbedCustomer(t *testing.T, pg *Postgres, tenant string, enabled bool) string {
	t.Helper()
	embed := uid("e-")
	err := pg.inTenant(context.Background(), tenant, func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), `INSERT INTO embed_customers (tenant_id, embed_id, allowed_origins, jwt_key_id, enabled)
			VALUES ($1, $2, '{https://example.com}', 'k1', $3)`, tenant, embed, enabled)
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return embed
}

// TestEmbedCustomerReads: the runtime role reads an embed by its id alone
// (the visitor's URL names no workspace) and gets its workspace; an unknown
// id is ErrNotFound. The staff list of a workspace holds its own embeds only:
// another workspace's embed is never in it.
func TestEmbedCustomerReads(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	on, off := seedEmbedCustomer(t, pg, a, true), seedEmbedCustomer(t, pg, a, false)
	other := seedEmbedCustomer(t, pg, b, true)

	e, err := rt.EmbedCustomer(ctx, on)
	if err != nil || e.TenantID != a || !e.Enabled || len(e.AllowedOrigins) != 1 || e.AllowedOrigins[0] != "https://example.com" ||
		e.JWTKeyID != "k1" || e.JWTPublicKey != "" || e.CreatedAt.IsZero() {
		t.Fatalf("EmbedCustomer(%s) = %+v, %v", on, e, err)
	}
	if e, err := rt.EmbedCustomer(ctx, off); err != nil || e.Enabled {
		t.Errorf("a disabled embed reads %+v, %v: want the row with Enabled false", e, err)
	}
	if _, err := rt.EmbedCustomer(ctx, uid("e-")); !errors.Is(err, ErrNotFound) {
		t.Errorf("an unknown embed: %v, want ErrNotFound", err)
	}

	list, err := rt.EmbedCustomers(ctx, a)
	if err != nil {
		t.Fatal(err)
	}
	got := map[string]bool{}
	for _, e := range list {
		got[e.EmbedID] = true
		if e.TenantID != a {
			t.Errorf("workspace %s's list holds %+v", a, e)
		}
	}
	if len(list) != 2 || !got[on] || !got[off] || got[other] {
		t.Errorf("workspace %s lists %v, want exactly %s and %s", a, got, on, off)
	}
	if _, err := rt.EmbedCustomers(ctx, ""); !errors.Is(err, ErrNoTenant) {
		t.Errorf("a list without a workspace: %v, want ErrNoTenant", err)
	}
}

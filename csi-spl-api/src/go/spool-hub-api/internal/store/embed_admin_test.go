package store

import (
	"context"
	"errors"
	"slices"
	"testing"
)

// TestEmbedAdminWrites (specs/121 T203): the runtime role creates an embed
// of its workspace (disabled, keyless), changes its origins and switch, and
// stores a public key. Another workspace can neither take the id nor change
// the row, and rdb 0169's checks surface as ErrBadEmbed.
func TestEmbedAdminWrites(t *testing.T) {
	pg := rlsStore(t)
	rt, _ := runtimeStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	id := uid("e-")

	e, err := rt.CreateEmbedCustomer(ctx, a, id, []string{"https://example.com"})
	if err != nil || e.TenantID != a || e.Enabled || e.JWTPublicKey != "" || !slices.Equal(e.AllowedOrigins, []string{"https://example.com"}) {
		t.Fatalf("create = %+v, %v", e, err)
	}
	if _, err := rt.CreateEmbedCustomer(ctx, b, id, nil); !errors.Is(err, ErrEmbedExists) {
		t.Errorf("CONTROL: another workspace took a used id: %v, want ErrEmbedExists", err)
	}
	if _, err := rt.CreateEmbedCustomer(ctx, a, "A_bad", nil); !errors.Is(err, ErrBadEmbed) {
		t.Errorf("CONTROL: bad id shape: %v, want ErrBadEmbed", err)
	}
	if _, err := rt.CreateEmbedCustomer(ctx, a, uid("e-"), []string{"*"}); !errors.Is(err, ErrBadEmbed) {
		t.Errorf("CONTROL: '*' origin: %v, want ErrBadEmbed", err)
	}

	on := true
	if e, err = rt.UpdateEmbedCustomer(ctx, a, id, nil, &on); err != nil || !e.Enabled || len(e.AllowedOrigins) != 1 {
		t.Fatalf("switch on, origins kept = %+v, %v", e, err)
	}
	two := []string{"https://example.com", "https://www.example.com"}
	if e, err = rt.UpdateEmbedCustomer(ctx, a, id, two, nil); err != nil || !e.Enabled || !slices.Equal(e.AllowedOrigins, two) {
		t.Fatalf("origins replaced, switch kept = %+v, %v", e, err)
	}
	if _, err := rt.UpdateEmbedCustomer(ctx, b, id, []string{}, nil); !errors.Is(err, ErrNotFound) {
		t.Errorf("CONTROL: another workspace changed the embed: %v, want ErrNotFound", err)
	}

	pub := "-----BEGIN PUBLIC KEY-----\nAAAA\n-----END PUBLIC KEY-----\n"
	if e, err = rt.SetEmbedKey(ctx, a, id, pub, "k-1"); err != nil || e.JWTPublicKey != pub || e.JWTKeyID != "k-1" {
		t.Fatalf("set key = %+v, %v", e, err)
	}
	priv := "-----BEGIN " + "PRIVATE KEY-----\nAAAA\n-----END " + "PRIVATE KEY-----\n"
	if _, err := rt.SetEmbedKey(ctx, a, id, priv, "k-2"); !errors.Is(err, ErrBadEmbed) {
		t.Errorf("CONTROL: a private key was stored: %v, want ErrBadEmbed", err)
	}
	if _, err := rt.SetEmbedKey(ctx, b, id, pub, "k-3"); !errors.Is(err, ErrNotFound) {
		t.Errorf("CONTROL: another workspace set the key: %v, want ErrNotFound", err)
	}
	if e, _ := rt.EmbedCustomer(ctx, id); e.JWTKeyID != "k-1" {
		t.Errorf("the refused writes changed the key id: %q, want k-1", e.JWTKeyID)
	}
}

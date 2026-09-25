package store

import (
	"context"
	"testing"
	"time"
)

func TestMembershipListsTenantDisplayName(t *testing.T) {
	ctx := context.Background()
	s := NewMemory()
	if err := s.CreateTenant(ctx, Tenant{ID: "acme", RootPubKey: pubkey(), DisplayName: "csitea"}); err != nil {
		t.Fatal(err)
	}
	var h Humans = s
	now := time.Now().UTC()
	id, err := h.Admit(ctx, Identity{Provider: "google", Subject: "sub-csitea", Email: "a@example.com", Name: "A"}, "acme", AdmitPolicy{BootstrapOwner: true}, now)
	if err != nil {
		t.Fatal(err)
	}
	ms, err := s.Memberships(ctx, id)
	if err != nil || len(ms) != 1 || ms[0].TenantID != "acme" || ms[0].DisplayName != "csitea" {
		t.Fatalf("memberships: %+v %v", ms, err)
	}
}

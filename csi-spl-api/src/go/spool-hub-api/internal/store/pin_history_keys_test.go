package store

import (
	"context"
	"crypto/ed25519"
	"os"
	"slices"
	"testing"
	"time"
)

// Spec 169 T4c: every key this workspace pinned for a box, each once, and only
// this workspace's: the history does not cross a tenant.
func TestPinHistoryKeys(t *testing.T) {
	stores := map[string]Store{"memory": NewMemory()}
	if os.Getenv("SPOOL_TEST_PG_DSN") != "" {
		stores["postgres"] = rlsStore(t)
	}
	for name, s := range stores {
		t.Run(name, func(t *testing.T) {
			ctx, now := context.Background(), time.Now()
			a, b := newTenant(t, s), newTenant(t, s)
			first, second, other := pubkey(), pubkey(), pubkey()
			if err := s.PutPin(ctx, a, "box-a", first, false, now, now); err != nil {
				t.Fatal(err)
			}
			if err := s.PutPin(ctx, a, "box-a", second, true, now.Add(time.Second), now.Add(time.Second)); err != nil {
				t.Fatal(err)
			}
			if err := s.RevokePin(ctx, a, "box-a", now.Add(2*time.Second), now.Add(2*time.Second)); err != nil {
				t.Fatal(err)
			}
			if err := s.PutPin(ctx, b, "box-a", other, false, now, now); err != nil {
				t.Fatal(err)
			}
			keys, err := s.PinHistoryKeys(ctx, a, "box-a")
			if err != nil {
				t.Fatal(err)
			}
			has := func(k ed25519.PublicKey) bool {
				return slices.ContainsFunc(keys, func(x ed25519.PublicKey) bool { return x.Equal(k) })
			}
			if len(keys) != 2 || !has(first) || !has(second) || has(other) {
				t.Fatalf("keys %d (first %v, second %v, other workspace %v)", len(keys), has(first), has(second), has(other))
			}
			if keys, err := s.PinHistoryKeys(ctx, a, "box-none"); err != nil || len(keys) != 0 {
				t.Fatalf("no such box: %d keys, %v", len(keys), err)
			}
		})
	}
}

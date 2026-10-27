package store

import (
	"context"
	"errors"
	"os"
	"testing"
	"time"
)

// Spec 127 H2 / spec 159 T5 (rdb 0233): the store half of a lease, the
// vendor's refusal a box reports, the manager's retry and the metered
// fall-back switch, on Memory and on Postgres (SPOOL_TEST_PG_DSN). The key
// row holds made-up bytes for the fake sk-test-0000, never a sealed real key.

func vendorKeyLeaseStores(t *testing.T) map[string]interface {
	Store
	VendorKeys
	VendorKeyLeases
} {
	out := map[string]interface {
		Store
		VendorKeys
		VendorKeyLeases
	}{"memory": NewMemory()}
	if os.Getenv("SPOOL_TEST_PG_DSN") != "" {
		out["postgres"] = rlsStore(t)
	}
	return out
}

func fakeVendorKeyPut(kind string) VendorKeyPut {
	return VendorKeyPut{Kind: kind, KeyID: uuid4(), Ciphertext: []byte{0, 0xfa, 0x4e}, WrappedDEK: []byte{0, 0xde, 0xc0},
		KMSKeyVersion: "test-kms-version-1", Last4: "0000", Fingerprint: "0000000000000000000000000000000000000000000000000000000000000000",
		Actor: "HUM-1"}
}

// TestVendorKeyLeaseExhaustedRetry is the store half of the T5 red control:
// a box's exhausted report makes the next lease read ErrVendorKeyExhausted,
// once; a retry or a replace makes the key usable again.
func TestVendorKeyLeaseExhaustedRetry(t *testing.T) {
	for name, s := range vendorKeyLeaseStores(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
			a, b := newTenant(t, s), newTenant(t, s)
			if _, err := s.VendorKeyForLease(ctx, a, "claude", "box-a"); !errors.Is(err, ErrVendorKeyBoxNotApproved) {
				t.Fatalf("unapproved box: %v, want ErrVendorKeyBoxNotApproved", err)
			}
			if err := s.ApproveVendorKeyBox(ctx, a, "box-a", "HUM-1", now); err != nil {
				t.Fatal(err)
			}
			if err := s.ApproveVendorKeyBox(ctx, a, "box-a", "HUM-1", now); err != nil {
				t.Fatalf("second approve: %v", err)
			}
			if _, err := s.VendorKeyForLease(ctx, a, "claude", "box-a"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("no key: %v, want ErrNotFound", err)
			}
			if _, err := s.PutVendorKey(ctx, a, fakeVendorKeyPut("claude"), now); err != nil {
				t.Fatal(err)
			}
			r, err := s.VendorKeyForLease(ctx, a, "claude", "box-a")
			if err != nil || r.Last4 != "0000" || len(r.Ciphertext) != 3 || r.KMSKeyVersion == "" {
				t.Fatalf("lease row %v, %v", r, err)
			}
			// Tenant scope: B's box approval and B's read never reach A's key (127 L1).
			if err := s.ApproveVendorKeyBox(ctx, b, "box-a", "HUM-2", now); err != nil {
				t.Fatal(err)
			}
			if _, err := s.VendorKeyForLease(ctx, b, "claude", "box-a"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("B reads A's key: %v, want ErrNotFound", err)
			}
			if err := s.AuditVendorKeyLease(ctx, a, "claude", "box-a", r.Last4, now); err != nil {
				t.Fatal(err)
			}
			first, last4, err := s.MarkVendorKeyExhausted(ctx, a, "claude", "box-a", now)
			if err != nil || !first || last4 != "0000" {
				t.Fatalf("mark: first=%v last4=%q err=%v", first, last4, err)
			}
			if first, _, err = s.MarkVendorKeyExhausted(ctx, a, "claude", "box-b", now); err != nil || first {
				t.Fatalf("second mark: first=%v err=%v, want not first", first, err)
			}
			if _, err := s.VendorKeyForLease(ctx, a, "claude", "box-a"); !errors.Is(err, ErrVendorKeyExhausted) {
				t.Fatalf("lease after the refusal: %v, want ErrVendorKeyExhausted", err)
			}
			rows, err := s.VendorKeys(ctx, a)
			if err != nil || len(rows) != 1 || !rows[0].ExhaustedAt.Equal(now) {
				t.Fatalf("GET rows %+v, %v: want exhausted_at %v", rows, err, now)
			}
			if _, _, err := s.MarkVendorKeyExhausted(ctx, a, "qwen", "box-a", now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("mark of an unset kind: %v, want ErrNotFound", err)
			}
			cleared, err := s.RetryVendorKey(ctx, a, "claude", "HUM-1", now)
			if err != nil || !cleared {
				t.Fatalf("retry: %v %v", cleared, err)
			}
			if cleared, err = s.RetryVendorKey(ctx, a, "claude", "HUM-1", now); err != nil || cleared {
				t.Fatalf("second retry: %v %v, want not cleared", cleared, err)
			}
			if _, err := s.VendorKeyForLease(ctx, a, "claude", "box-a"); err != nil {
				t.Fatalf("lease after retry: %v", err)
			}
			// A replace clears the state too.
			if _, _, err := s.MarkVendorKeyExhausted(ctx, a, "claude", "box-a", now); err != nil {
				t.Fatal(err)
			}
			if _, err := s.PutVendorKey(ctx, a, fakeVendorKeyPut("claude"), now); err != nil {
				t.Fatal(err)
			}
			if _, err := s.VendorKeyForLease(ctx, a, "claude", "box-a"); err != nil {
				t.Fatalf("lease after replace: %v", err)
			}
			if err := s.RevokeVendorKeyBox(ctx, a, "box-a", "HUM-1", now); err != nil {
				t.Fatal(err)
			}
			if err := s.RevokeVendorKeyBox(ctx, a, "box-a", "HUM-1", now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("second revoke: %v, want ErrNotFound", err)
			}
			if _, err := s.VendorKeyForLease(ctx, a, "claude", "box-a"); !errors.Is(err, ErrVendorKeyBoxNotApproved) {
				t.Fatalf("revoked box: %v", err)
			}
		})
	}
}

// TestVendorKeyMeteredFallback: off by default (159 9, owner Q-2 B), on and
// off again, per workspace.
func TestVendorKeyMeteredFallback(t *testing.T) {
	for name, s := range vendorKeyLeaseStores(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Date(2026, 10, 27, 12, 0, 0, 0, time.UTC)
			a, b := newTenant(t, s), newTenant(t, s)
			if on, err := s.VendorKeyMeteredFallback(ctx, a); err != nil || on {
				t.Fatalf("default: %v %v, want off", on, err)
			}
			for _, on := range []bool{true, true, false, true} {
				if err := s.SetVendorKeyMeteredFallback(ctx, a, on, "HUM-1", now); err != nil {
					t.Fatal(err)
				}
				if got, err := s.VendorKeyMeteredFallback(ctx, a); err != nil || got != on {
					t.Fatalf("after set %v: %v %v", on, got, err)
				}
			}
			if on, err := s.VendorKeyMeteredFallback(ctx, b); err != nil || on {
				t.Fatalf("B follows A: %v %v", on, err)
			}
			if err := s.SetVendorKeyMeteredFallback(ctx, "t-nobody", true, "HUM-1", now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("no tenant: %v, want ErrNotFound", err)
			}
		})
	}
}

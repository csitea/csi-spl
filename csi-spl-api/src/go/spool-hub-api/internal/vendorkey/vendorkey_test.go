package vendorkey_test

import (
	"bytes"
	"context"
	"errors"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/marketing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/vendorkey"
)

// Spec 127 4.2: the row opens only for its own tenant, kind and key_id, the
// ciphertext never carries the key, and the fingerprint is a keyed HMAC.

const fake = "sk-test-0000"

func sealer(t *testing.T, pepper string) *vendorkey.Sealer {
	t.Helper()
	s, err := vendorkey.NewSealer(marketing.NewFakeKMS(), "projects/p/locations/l/keyRings/r/cryptoKeys/k", []byte(pepper))
	if err != nil {
		t.Fatal(err)
	}
	return s
}

func TestSealOpensOnlyForItsRow(t *testing.T) {
	ctx := context.Background()
	s := sealer(t, "0123456789abcdef-pepper")
	row, err := s.Seal(ctx, "ta", "claude", "k1", fake)
	if err != nil {
		t.Fatal(err)
	}
	if bytes.Contains(row.Ciphertext, []byte(fake)) || bytes.Contains(row.WrappedDEK, []byte(fake)) {
		t.Fatal("the sealed row carries the key in the clear")
	}
	if row.Last4 != "0000" || len(row.Fingerprint) != 64 || row.KMSKeyVersion == "" {
		t.Fatalf("row: last4 %q fingerprint %q version %q", row.Last4, row.Fingerprint, row.KMSKeyVersion)
	}
	got, err := s.Open(ctx, "ta", "claude", "k1", row)
	if err != nil || got != fake {
		t.Fatalf("open own row: %q %v", got, err)
	}
	for _, c := range [][3]string{{"tb", "claude", "k1"}, {"ta", "qwen", "k1"}, {"ta", "claude", "k2"}} {
		if _, err := s.Open(ctx, c[0], c[1], c[2], row); !errors.Is(err, vendorkey.ErrOpen) {
			t.Fatalf("open as %v: %v, want ErrOpen", c, err)
		}
	}
	row.Ciphertext[len(row.Ciphertext)-1] ^= 1
	if _, err := s.Open(ctx, "ta", "claude", "k1", row); !errors.Is(err, vendorkey.ErrOpen) {
		t.Fatalf("tampered: %v, want ErrOpen", err)
	}
}

func TestFingerprintIsKeyedByThePepper(t *testing.T) {
	a, b := sealer(t, "pepper-one-0123456789"), sealer(t, "pepper-two-0123456789")
	if a.Fingerprint(fake) != a.Fingerprint(fake) {
		t.Fatal("fingerprint not stable")
	}
	if a.Fingerprint(fake) == b.Fingerprint(fake) {
		t.Fatal("two peppers give one fingerprint: not keyed")
	}
}

func TestNewSealerRefusesMissingParts(t *testing.T) {
	k := marketing.NewFakeKMS()
	for name, c := range map[string]struct {
		kms    vendorkey.KMS
		key    string
		pepper string
	}{
		"no kms":       {nil, "k", "0123456789abcdef"},
		"no key name":  {k, " ", "0123456789abcdef"},
		"short pepper": {k, "k", "short"},
	} {
		if _, err := vendorkey.NewSealer(c.kms, c.key, []byte(c.pepper)); err == nil {
			t.Fatalf("%s: accepted", name)
		}
	}
}

func TestLast4(t *testing.T) {
	for in, want := range map[string]string{fake: "0000", "abc": "abc", "": ""} {
		if got := vendorkey.Last4(in); got != want {
			t.Fatalf("Last4(%q) = %q, want %q", in, got, want)
		}
	}
}

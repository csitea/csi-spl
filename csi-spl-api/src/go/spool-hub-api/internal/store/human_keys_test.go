package store

import (
	"context"
	"crypto/ed25519"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
)

func humanKeyRow(hum, source string) HumanKey {
	pub, _, _ := ed25519.GenerateKey(nil)
	return HumanKey{HumanID: hum, PublicKey: sign.PinForm(pub), Fingerprint: sign.Fingerprint(pub), Source: source}
}

// 023 T011: one active key per human, a new key replaces it (history kept),
// revoke is idempotent, keys never cross humans, a public key registers once.
func TestHumanKeys(t *testing.T) {
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	for name, s := range drivers(t) {
		h, k := s.(Humans), s.(HumanKeys)
		t.Run(name, func(t *testing.T) {
			alice, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("a-")}, "", AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}
			bob, err := h.Admit(ctx, Identity{Provider: "google", Subject: uid("b-")}, "", AdmitPolicy{}, now)
			if err != nil {
				t.Fatal(err)
			}
			if l, err := k.HumanKeys(ctx, alice); err != nil || len(l) != 0 {
				t.Fatalf("fresh human has keys: %v %v", l, err)
			}
			first, err := k.AddHumanKey(ctx, humanKeyRow(alice, KeySourceGenerated), now)
			if err != nil || first.ID == 0 || first.RevokedAt != nil {
				t.Fatalf("add: %+v %v", first, err)
			}
			second, err := k.AddHumanKey(ctx, humanKeyRow(alice, KeySourceUploaded), now.Add(time.Second))
			if err != nil {
				t.Fatal(err)
			}
			l, err := k.HumanKeys(ctx, alice)
			if err != nil || len(l) != 2 || l[0].ID != second.ID || l[0].RevokedAt != nil ||
				l[1].RevokedAt == nil || l[1].RevokedReason != KeyRevokedReplaced {
				t.Fatalf("replace keeps history, newest first: %+v %v", l, err)
			}

			// CONTROL: the same public key again, for anyone, is a conflict.
			dup := humanKeyRow(bob, KeySourceUploaded)
			dup.PublicKey, dup.Fingerprint = second.PublicKey, second.Fingerprint
			if _, err := k.AddHumanKey(ctx, dup, now); !errors.Is(err, ErrConflict) {
				t.Fatalf("duplicate across humans: %v", err)
			}
			if bl, _ := k.HumanKeys(ctx, bob); len(bl) != 0 {
				t.Fatalf("refused add wrote a row: %+v", bl)
			}
			// CONTROL: bob cannot read or revoke alice's key.
			if _, err := k.HumanKey(ctx, bob, second.ID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("cross-human get: %v", err)
			}
			if _, err := k.RevokeHumanKey(ctx, bob, second.ID, now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("cross-human revoke: %v", err)
			}
			if got, _ := k.HumanKey(ctx, alice, second.ID); got.RevokedAt != nil {
				t.Fatalf("bob's revoke touched alice's key: %+v", got)
			}

			r, err := k.RevokeHumanKey(ctx, alice, second.ID, now.Add(2*time.Second))
			if err != nil || r.RevokedAt == nil || r.RevokedReason != KeyRevokedByUser {
				t.Fatalf("revoke: %+v %v", r, err)
			}
			again, err := k.RevokeHumanKey(ctx, alice, second.ID, now.Add(time.Hour))
			if err != nil || !again.RevokedAt.Equal(*r.RevokedAt) {
				t.Fatalf("revoke is idempotent: %+v %v", again, err)
			}
			if _, err := k.AddHumanKey(ctx, humanKeyRow("HUM-999999999", KeySourceUploaded), now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown human: %v", err)
			}
			bad := humanKeyRow(alice, "stolen")
			if _, err := k.AddHumanKey(ctx, bad, now); err == nil {
				t.Fatal("bad source accepted")
			}
		})
	}
}

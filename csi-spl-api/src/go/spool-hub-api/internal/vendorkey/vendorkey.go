// Package vendorkey seals a workspace's own vendor key (spec 127 v1.4
// section 4.2, spec 159 T1): a fresh 256-bit data key per row, the key
// sealed with AES-256-GCM under the additional data tenant_id|kind|key_id,
// the data key wrapped by Cloud KMS. The row holds ciphertext, the wrapped
// key and the KMS key version only, so a database dump, a statement log or a
// backup without the KMS key reveals no vendor key. The fingerprint is
// HMAC-SHA256 of the key under the hub's pepper, never a bare hash.
//
// The plaintext key lives in the hub for one request; nothing here logs,
// prints or returns it except Open, which only the lease route (spec 127
// H2) is meant to call.
package vendorkey

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"strings"
)

// KMS is the slice of Cloud KMS the seal needs; marketing.CloudKMS and
// marketing.FakeKMS implement it. keyName is the full CryptoKey resource name.
type KMS interface {
	Encrypt(ctx context.Context, keyName string, plaintext []byte) (wrapped []byte, keyVersion string, err error)
	Decrypt(ctx context.Context, keyName string, wrapped []byte) ([]byte, error)
}

// ErrOpen is any sealed row that does not open: another tenant, kind or
// key_id in the additional data, a wrapped key KMS refuses, or tampering.
var ErrOpen = errors.New("vendorkey: sealed key does not open")

// MinPepper is the shortest pepper NewSealer takes, in bytes.
const MinPepper = 16

// Sealed is what the workspace_vendor_keys row stores (rdb 0174).
type Sealed struct {
	Ciphertext    []byte // nonce || AES-256-GCM sealed key
	WrappedDEK    []byte
	KMSKeyVersion string
	Last4         string
	Fingerprint   string // hex HMAC-SHA256 under the pepper
}

// Sealer seals and opens vendor keys with one KMS key and one pepper.
type Sealer struct {
	kms     KMS
	keyName string
	pepper  []byte
	rand    io.Reader
}

// NewSealer returns a Sealer. A missing client, key name or pepper is an
// error: there is no unsealed fallback.
func NewSealer(kms KMS, keyName string, pepper []byte) (*Sealer, error) {
	switch {
	case kms == nil:
		return nil, errors.New("vendorkey: seal needs a KMS client")
	case strings.TrimSpace(keyName) == "":
		return nil, errors.New("vendorkey: seal needs a KMS key name (cnf vendor_keys.kms_key)")
	case len(pepper) < MinPepper:
		return nil, errors.New("vendorkey: seal needs a pepper of at least 16 bytes (cnf vendor_keys.pepper_secret)")
	}
	return &Sealer{kms: kms, keyName: keyName, pepper: append([]byte(nil), pepper...), rand: rand.Reader}, nil
}

// aad binds a sealed key to its row (spec 127 4.2): a ciphertext copied into
// another workspace's row, another kind, or over a newer key fails to open.
func aad(tenant, kind, keyID string) []byte {
	return []byte(tenant + "|" + kind + "|" + keyID)
}

// Seal encrypts key for (tenant, kind, keyID) under a fresh data key.
func (s *Sealer) Seal(ctx context.Context, tenant, kind, keyID, key string) (Sealed, error) {
	dek := make([]byte, 32)
	defer clear(dek)
	if _, err := io.ReadFull(s.rand, dek); err != nil {
		return Sealed{}, fmt.Errorf("vendorkey: data key: %w", err)
	}
	gcm, err := newGCM(dek)
	if err != nil {
		return Sealed{}, err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(s.rand, nonce); err != nil {
		return Sealed{}, fmt.Errorf("vendorkey: nonce: %w", err)
	}
	plain := []byte(key)
	defer clear(plain)
	box := gcm.Seal(nonce, nonce, plain, aad(tenant, kind, keyID))
	wrapped, version, err := s.kms.Encrypt(ctx, s.keyName, dek)
	if err != nil {
		return Sealed{}, fmt.Errorf("vendorkey: kms wrap: %w", err)
	}
	return Sealed{Ciphertext: box, WrappedDEK: wrapped, KMSKeyVersion: version,
		Last4: Last4(key), Fingerprint: s.Fingerprint(key)}, nil
}

// Open reverses Seal for the same (tenant, kind, keyID). Any failure is
// ErrOpen (wrapped), never a partial key.
func (s *Sealer) Open(ctx context.Context, tenant, kind, keyID string, row Sealed) (string, error) {
	dek, err := s.kms.Decrypt(ctx, s.keyName, row.WrappedDEK)
	if err != nil {
		return "", fmt.Errorf("%w: kms unwrap: %w", ErrOpen, err)
	}
	defer clear(dek)
	gcm, err := newGCM(dek)
	if err != nil {
		return "", fmt.Errorf("%w: %w", ErrOpen, err)
	}
	n := gcm.NonceSize()
	if len(row.Ciphertext) < n+gcm.Overhead() {
		return "", fmt.Errorf("%w: short ciphertext", ErrOpen)
	}
	out, err := gcm.Open(nil, row.Ciphertext[:n], row.Ciphertext[n:], aad(tenant, kind, keyID))
	if err != nil {
		return "", fmt.Errorf("%w: %w", ErrOpen, err)
	}
	return string(out), nil
}

// Fingerprint is the hex HMAC-SHA256 of key under the pepper (spec 127 L9).
func (s *Sealer) Fingerprint(key string) string {
	m := hmac.New(sha256.New, s.pepper)
	m.Write([]byte(key)) //nolint:errcheck // hash.Hash.Write never fails
	return hex.EncodeToString(m.Sum(nil))
}

// Last4 is the last four characters of key, the only part the hub shows.
func Last4(key string) string {
	r := []rune(key)
	if len(r) <= 4 {
		return string(r)
	}
	return string(r[len(r)-4:])
}

func newGCM(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("vendorkey: aes: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("vendorkey: gcm: %w", err)
	}
	return gcm, nil
}

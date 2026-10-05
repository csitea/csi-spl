// Package marketing holds the spec 090 marketing automation pieces.
//
// seal.go is the envelope seal for connected-channel OAuth tokens (spec 090
// T005, FR-002): every token gets its own AES-256-GCM data key, and Cloud KMS
// wraps that data key under the cnf key `marketing.kms_key`. Only the sealed
// text and the KMS key version reach the `marketing_channel_tokens` row, so a
// database dump without the KMS key reveals no credential.
package marketing

import (
	"context"
	"crypto/aes"
	"crypto/cipher"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"strings"
)

// redacted is what every printed or encoded form of a Plaintext shows.
const redacted = "[redacted]"

// sealVersion prefixes every sealed text, so a later format can be told apart.
const sealVersion = "v1"

// sealAAD binds the GCM tag to this format, so a blob sealed for another
// purpose with the same data key never opens here.
var sealAAD = []byte("spool-marketing-seal/" + sealVersion)

// ErrOpen is returned for any sealed text that does not open: bad format, a
// wrapped key KMS refuses, or a GCM tag that does not match (tampering).
var ErrOpen = errors.New("marketing: sealed token does not open")

// KMS is the small slice of Cloud KMS the seal needs. keyName is the full
// CryptoKey resource name. Encrypt returns the wrapped bytes and the name of
// the CryptoKeyVersion that wrapped them.
type KMS interface {
	Encrypt(ctx context.Context, keyName string, plaintext []byte) (wrapped []byte, keyVersion string, err error)
	Decrypt(ctx context.Context, keyName string, wrapped []byte) ([]byte, error)
}

// Plaintext holds a secret (an OAuth token). It never prints or encodes its
// value: String, GoString, Format, MarshalJSON, MarshalText and LogValue all
// give "[redacted]". Reveal is the one way to read it.
type Plaintext struct{ s string }

// NewPlaintext wraps a secret.
func NewPlaintext(s string) Plaintext { return Plaintext{s: s} }

// Reveal returns the secret. Call it only at the point of use (an API call).
func (p Plaintext) Reveal() string { return p.s }

// String implements fmt.Stringer.
func (Plaintext) String() string { return redacted }

// GoString implements fmt.GoStringer (%#v).
func (Plaintext) GoString() string { return redacted }

// Format covers every fmt verb, including %+v on a struct holding a Plaintext.
func (Plaintext) Format(f fmt.State, _ rune) { _, _ = io.WriteString(f, redacted) }

// MarshalJSON implements json.Marshaler.
func (Plaintext) MarshalJSON() ([]byte, error) { return []byte(`"` + redacted + `"`), nil }

// MarshalText implements encoding.TextMarshaler (map keys, text encoders).
func (Plaintext) MarshalText() ([]byte, error) { return []byte(redacted), nil }

// LogValue implements slog.LogValuer.
func (Plaintext) LogValue() slog.Value { return slog.StringValue(redacted) }

// Sealer seals and opens tokens with one KMS key.
type Sealer struct {
	kms     KMS
	keyName string
	rand    io.Reader
}

// NewSealer returns a Sealer for keyName (cnf `marketing.kms_key`). A missing
// client or key name is an error: there is no unsealed fallback.
func NewSealer(kms KMS, keyName string) (*Sealer, error) {
	if kms == nil {
		return nil, errors.New("marketing: seal needs a KMS client")
	}
	if strings.TrimSpace(keyName) == "" {
		return nil, errors.New("marketing: seal needs a KMS key name (cnf marketing.kms_key)")
	}
	return &Sealer{kms: kms, keyName: keyName, rand: rand.Reader}, nil
}

// Seal encrypts p under a fresh data key and returns the sealed text
// ("v1.<wrapped key>.<nonce+ciphertext>", base64url) and the KMS key version
// that wrapped the data key.
func (s *Sealer) Seal(ctx context.Context, p Plaintext) (ciphertext, kmsKeyID string, err error) {
	dek := make([]byte, 32)
	defer clear(dek)
	if _, err := io.ReadFull(s.rand, dek); err != nil {
		return "", "", fmt.Errorf("marketing: data key: %w", err)
	}
	gcm, err := newGCM(dek)
	if err != nil {
		return "", "", err
	}
	nonce := make([]byte, gcm.NonceSize())
	if _, err := io.ReadFull(s.rand, nonce); err != nil {
		return "", "", fmt.Errorf("marketing: nonce: %w", err)
	}
	box := gcm.Seal(nonce, nonce, []byte(p.s), sealAAD)
	wrapped, keyVersion, err := s.kms.Encrypt(ctx, s.keyName, dek)
	if err != nil {
		return "", "", fmt.Errorf("marketing: kms wrap: %w", err)
	}
	enc := base64.RawURLEncoding
	return sealVersion + "." + enc.EncodeToString(wrapped) + "." + enc.EncodeToString(box), keyVersion, nil
}

// Open reverses Seal. Any failure is ErrOpen (wrapped), never a partial text.
func (s *Sealer) Open(ctx context.Context, ciphertext string) (Plaintext, error) {
	wrapped, box, err := splitSealed(ciphertext)
	if err != nil {
		return Plaintext{}, err
	}
	dek, err := s.kms.Decrypt(ctx, s.keyName, wrapped)
	if err != nil {
		return Plaintext{}, fmt.Errorf("%w: kms unwrap: %v", ErrOpen, err)
	}
	defer clear(dek)
	gcm, err := newGCM(dek)
	if err != nil {
		return Plaintext{}, fmt.Errorf("%w: %v", ErrOpen, err)
	}
	n := gcm.NonceSize()
	if len(box) < n+gcm.Overhead() {
		return Plaintext{}, fmt.Errorf("%w: short ciphertext", ErrOpen)
	}
	out, err := gcm.Open(nil, box[:n], box[n:], sealAAD)
	if err != nil {
		return Plaintext{}, fmt.Errorf("%w: %v", ErrOpen, err)
	}
	return Plaintext{s: string(out)}, nil
}

// splitSealed parses "v1.<wrapped>.<box>".
func splitSealed(sealed string) (wrapped, box []byte, err error) {
	parts := strings.Split(sealed, ".")
	if len(parts) != 3 || parts[0] != sealVersion {
		return nil, nil, fmt.Errorf("%w: not a %s sealed text", ErrOpen, sealVersion)
	}
	enc := base64.RawURLEncoding
	if wrapped, err = enc.DecodeString(parts[1]); err != nil {
		return nil, nil, fmt.Errorf("%w: wrapped key: %v", ErrOpen, err)
	}
	if box, err = enc.DecodeString(parts[2]); err != nil {
		return nil, nil, fmt.Errorf("%w: body: %v", ErrOpen, err)
	}
	return wrapped, box, nil
}

func newGCM(key []byte) (cipher.AEAD, error) {
	block, err := aes.NewCipher(key)
	if err != nil {
		return nil, fmt.Errorf("marketing: aes: %w", err)
	}
	gcm, err := cipher.NewGCM(block)
	if err != nil {
		return nil, fmt.Errorf("marketing: gcm: %w", err)
	}
	return gcm, nil
}

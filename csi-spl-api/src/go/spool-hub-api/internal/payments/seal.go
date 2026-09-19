package payments

import (
	"crypto/aes"
	"crypto/cipher"
	"crypto/ed25519"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"errors"
	"strings"
)

// The root private key between checkout and claim (checkout-v1 §0.2): sealed
// with AES-256-GCM under a key derived from the buyer's claim token, bound to
// the checkout id. The hub keeps the seal and ClaimHash(token); with neither
// the token nor the key it cannot open the seal.

var errSeal = errors.New("payments: sealed key does not open")

// NewClaimToken returns a fresh 256-bit bearer token (base64url, no padding).
func NewClaimToken() string {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		panic(err)
	}
	return base64.RawURLEncoding.EncodeToString(b)
}

// ClaimHash is what the store keeps: SHA-256 over a domain tag and the token.
func ClaimHash(token string) []byte {
	h := sha256.Sum256([]byte("spool-checkout-claim-v1\x00" + strings.TrimSpace(token)))
	return h[:]
}

func sealKey(token string) []byte {
	m := hmac.New(sha256.New, []byte(strings.TrimSpace(token)))
	m.Write([]byte("spool-checkout-seal-v1"))
	return m.Sum(nil)
}

func gcm(token string) (cipher.AEAD, error) {
	block, err := aes.NewCipher(sealKey(token))
	if err != nil {
		return nil, err
	}
	return cipher.NewGCM(block)
}

// Seal encrypts priv for checkoutID under token: nonce || ciphertext.
func Seal(token, checkoutID string, priv ed25519.PrivateKey) ([]byte, error) {
	a, err := gcm(token)
	if err != nil {
		return nil, err
	}
	nonce := make([]byte, a.NonceSize())
	if _, err := rand.Read(nonce); err != nil {
		return nil, err
	}
	return a.Seal(nonce, nonce, priv, []byte(checkoutID)), nil
}

// Open reverses Seal; any mismatch (token, checkout id, tampering) fails.
func Open(token, checkoutID string, sealed []byte) (ed25519.PrivateKey, error) {
	a, err := gcm(token)
	if err != nil {
		return nil, err
	}
	if len(sealed) < a.NonceSize() {
		return nil, errSeal
	}
	pt, err := a.Open(nil, sealed[:a.NonceSize()], sealed[a.NonceSize():], []byte(checkoutID))
	if err != nil || len(pt) != ed25519.PrivateKeySize {
		return nil, errSeal
	}
	return ed25519.PrivateKey(pt), nil
}

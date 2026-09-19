package payments

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"strings"
)

// Claim tokens (checkout-v1 §0.2, 017 T008 / SEC-03): single-use bearer
// tokens that let the buyer mint and see the tenant root private key ONCE.
// The hub keeps only ClaimHash(token); the key itself is minted at the claim
// and never stored or emailed.

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

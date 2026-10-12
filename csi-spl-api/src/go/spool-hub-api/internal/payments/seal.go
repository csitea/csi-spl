package payments

import (
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"fmt"
	"strings"
)

// readEntropy is crypto/rand.Read. Tests replace it to drive a failure on
// the checkout request path, where a panic used to abort the process.
var readEntropy = rand.Read

// Claim tokens (checkout-v1 §0.2, 017 T008 / SEC-03): single-use bearer
// tokens that let the buyer mint and see the tenant root private key ONCE.
// The hub keeps only ClaimHash(token); the key itself is minted at the claim
// and never stored or emailed.

// NewClaimToken returns a fresh 256-bit bearer token (base64url, no padding).
// A read failure is returned: this runs on the checkout request path.
func NewClaimToken() (string, error) {
	b := make([]byte, 32)
	if _, err := readEntropy(b); err != nil {
		return "", fmt.Errorf("payments: claim token: %w", err)
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// ClaimHash is what the store keeps: SHA-256 over a domain tag and the token.
func ClaimHash(token string) []byte {
	h := sha256.Sum256([]byte("spool-checkout-claim-v1\x00" + strings.TrimSpace(token)))
	return h[:]
}

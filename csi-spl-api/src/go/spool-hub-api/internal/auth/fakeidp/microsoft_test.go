package fakeidp

import (
	"crypto/rsa"
	"testing"
)

// A key with no modulus is the failure rsa.SignPKCS1v15 returns. signRS256
// used to panic on that error; the token route returns it instead.
func TestSignRS256ReturnsErrorWhenKeyMissing(t *testing.T) {
	f := &IdP{msKey: &rsa.PrivateKey{}}
	tok, err := f.signRS256(map[string]any{"alg": "RS256"}, map[string]any{"sub": "x"}, false)
	if err == nil || tok != "" {
		t.Fatalf("got %q %v", tok, err)
	}
}

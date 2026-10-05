package payments

import (
	"context"
	"crypto"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"encoding/base64"
	"testing"
	"time"
)

// publicKey fetches a certificate once and serves later verifies from the
// cache (refactor round 3, row 3: the cert cache had no test).
func TestPayPalVerifierCachesCert(t *testing.T) {
	key, certPEM := selfSignedCert(t)
	fetches := 0
	v := &PayPalVerifier{WebhookID: "wh-1", Fetch: func(context.Context, string) ([]byte, error) {
		fetches++
		return certPEM, nil
	}}
	h := PayPalHeaders{TransmissionID: "tx-1", TransmissionTime: time.Now().UTC().Format(time.RFC3339),
		CertURL: "https://api.paypal.com/cert.pem", AuthAlgo: "SHA256withRSA"}
	body := `{"id":"WH-1"}`
	d := sha256.Sum256([]byte(PayPalSignedMessage(h.TransmissionID, h.TransmissionTime, v.WebhookID, body)))
	sig, err := rsa.SignPKCS1v15(rand.Reader, key, crypto.SHA256, d[:])
	if err != nil {
		t.Fatal(err)
	}
	h.TransmissionSig = base64.StdEncoding.EncodeToString(sig)

	for i := 0; i < 2; i++ {
		if err := v.Verify(t.Context(), h, body); err != nil {
			t.Fatalf("verify %d: %v", i+1, err)
		}
	}
	if fetches != 1 {
		t.Fatalf("two verifies fetched the cert %d times, want 1", fetches)
	}
}

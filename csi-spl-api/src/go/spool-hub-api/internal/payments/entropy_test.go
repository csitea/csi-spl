package payments

import (
	"errors"
	"net/http"
	"testing"
)

func TestClaimTokenAndCheckoutIDReturnEntropyError(t *testing.T) {
	orig := readEntropy
	t.Cleanup(func() { readEntropy = orig })
	readEntropy = func([]byte) (int, error) { return 0, errors.New("no entropy") }

	tok, err := NewClaimToken()
	if err == nil || tok != "" {
		t.Fatalf("claim token: got %q %v", tok, err)
	}
	id, err := newCheckoutID()
	if err == nil || id != "" {
		t.Fatalf("checkout id: got %q %v", id, err)
	}
}

func TestCheckoutAnswers500WhenEntropyFails(t *testing.T) {
	orig := readEntropy
	t.Cleanup(func() { readEntropy = orig })
	readEntropy = func([]byte) (int, error) { return 0, errors.New("no entropy") }

	cfg := mustLoad(t, "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000"})
	r := newRig(t, cfg)
	code, body := r.do(t, "POST", "/api/v1/checkout", map[string]string{"tenant_id": "acme", "email": "buyer@example.com"})
	if code != http.StatusInternalServerError || body["error"] != "internal" {
		t.Fatalf("checkout %d %v", code, body)
	}
}

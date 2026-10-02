package payments

import (
	"bytes"
	"context"
	"errors"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Pins of POST /checkout taken before checkout() was split into named steps
// (SPL-1029 round 2): each refusal's status and error token, and that a
// payment the hub failed to hold is cancelled at the provider.

type flakyStore struct {
	*store.Memory
	lookupErr, holdErr error
}

func (s *flakyStore) GetTenant(ctx context.Context, id string) (store.Tenant, error) {
	if s.lookupErr != nil {
		return store.Tenant{}, s.lookupErr
	}
	return s.Memory.GetTenant(ctx, id)
}

func (s *flakyStore) HoldCheckout(ctx context.Context, c store.Checkout, now time.Time, hold time.Duration) error {
	if s.holdErr != nil {
		return s.holdErr
	}
	return s.Memory.HoldCheckout(ctx, c, now, hold)
}

type recordingCard struct {
	PaymentProvider
	createErr, cancelErr error
	cancelled            []string
}

func (c *recordingCard) CreateIntent(ctx context.Context, id string, total int, cur string) (string, string, error) {
	if c.createErr != nil {
		return "", "", c.createErr
	}
	return c.PaymentProvider.CreateIntent(ctx, id, total, cur)
}

func (c *recordingCard) CancelIntent(ctx context.Context, id string) error {
	c.cancelled = append(c.cancelled, id)
	return c.cancelErr
}

// A failed hold whose provider-side cancel ALSO fails is logged with the
// payment ref (CLE-77915: the cancel's error used to be discarded).
func TestCheckoutCancelFailureIsLogged(t *testing.T) {
	cfg := mustLoad(t, "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000"})
	for _, cancelErr := range []error{errors.New("provider down"), nil} {
		st := flakyStore{Memory: store.NewMemory(), holdErr: errors.New("db down")}
		base, _, _ := Wire(cfg)
		card := &recordingCard{PaymentProvider: base, cancelErr: cancelErr}
		logs := &bytes.Buffer{}
		h, err := New(cfg, Deps{Store: &st, Log: zerolog.New(logs), Mail: &mail.Recorder{}, MailDelivers: true,
			TenantHostPattern: pattern, Card: card})
		if err != nil {
			t.Fatal(err)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("POST", "/api/v1/checkout", strings.NewReader(`{"tenant_id":"acme","email":"buyer@example.com"}`)))
		logged := strings.Contains(logs.String(), "the payment could not be cancelled")
		if w.Code != 500 || len(card.cancelled) != 1 || logged != (cancelErr != nil) {
			t.Errorf("cancelErr=%v: code %d, cancels %d, logged %v", cancelErr, w.Code, len(card.cancelled), logged)
		}
		if cancelErr != nil && !strings.Contains(logs.String(), card.cancelled[0]) {
			t.Errorf("the log does not name the payment ref %q: %s", card.cancelled[0], logs.String())
		}
	}
}

func TestCheckoutRefusals(t *testing.T) {
	cfg := mustLoad(t, "dev", map[string]string{"SPOOL_HUB_ENABLE_FAKE_PAY": "true", "SPOOL_HUB_PAYMENT_PLAN_CENTS": "2000"})
	good := `{"tenant_id":"acme","email":"buyer@example.com"}`
	cases := []struct {
		name      string
		body      string
		st        flakyStore
		createErr error
		code      int
		token     string
		cancelled bool
	}{
		{"not json", `{`, flakyStore{}, nil, 400, "bad_request", false},
		{"bad method", `{"tenant_id":"acme","email":"buyer@example.com","method":"bitcoin"}`, flakyStore{}, nil, 400, "bad_method", false},
		{"paypal off", `{"tenant_id":"acme","email":"buyer@example.com","method":" PayPal "}`, flakyStore{}, nil, 503, "payment_unavailable", false},
		{"lookup fails", good, flakyStore{lookupErr: errors.New("db down")}, nil, 500, "internal", false},
		{"provider refuses", good, flakyStore{}, errors.New("card declined"), 503, "payment_unavailable", false},
		{"hold conflict", good, flakyStore{holdErr: store.ErrConflict}, nil, 409, "tenant_taken", true},
		{"hold fails", good, flakyStore{holdErr: errors.New("db down")}, nil, 500, "internal", true},
	}
	for _, c := range cases {
		st := c.st
		st.Memory = store.NewMemory()
		base, _, _ := Wire(cfg)
		card := &recordingCard{PaymentProvider: base, createErr: c.createErr}
		h, err := New(cfg, Deps{Store: &st, Log: zerolog.New(&bytes.Buffer{}), Mail: &mail.Recorder{}, MailDelivers: true,
			TenantHostPattern: pattern, Card: card})
		if err != nil {
			t.Fatal(err)
		}
		w := httptest.NewRecorder()
		h.ServeHTTP(w, httptest.NewRequest("POST", "/api/v1/checkout", strings.NewReader(c.body)))
		if w.Code != c.code || !strings.Contains(w.Body.String(), `"error":"`+c.token+`"`) {
			t.Errorf("%s: %d %s, want %d %s", c.name, w.Code, w.Body.String(), c.code, c.token)
		}
		if (len(card.cancelled) == 1) != c.cancelled || (c.cancelled && card.cancelled[0] == "") {
			t.Errorf("%s: cancelled %q, want a cancel: %v", c.name, card.cancelled, c.cancelled)
		}
	}
}

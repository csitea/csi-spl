package payments

import (
	"bytes"
	"context"
	"errors"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// kuStore is a Store whose only live method is TenantHost: any other call
// panics on the nil embedded interface, so these tests touch nothing else.
type kuStore struct {
	Store
	err error
}

func (s kuStore) TenantHost(context.Context, string) (store.TenantHost, error) {
	return store.TenantHost{}, s.err
}

func kuHostStatus(t *testing.T, readErr error) (status, logs string) {
	t.Helper()
	var buf bytes.Buffer
	h := &Handler{d: Deps{Store: kuStore{err: readErr}, Log: zerolog.New(&buf)}}
	status = h.hostStatus(t.Context(), "acme")
	return status, buf.String()
}

func TestPaypalKind(t *testing.T) {
	for _, tc := range []struct{ event, want string }{
		{"PAYMENT.CAPTURE.COMPLETED", store.PayEventPaid},
		{"PAYMENT.CAPTURE.REFUNDED", store.PayEventRefund},
		{"PAYMENT.CAPTURE.REVERSED", store.PayEventRefund},
		{"CHECKOUT.ORDER.APPROVED", store.PayEventIgnore},
		{"", store.PayEventIgnore},
	} {
		if got := paypalKind(tc.event); got != tc.want {
			t.Errorf("paypalKind(%q) = %q, want %q", tc.event, got, tc.want)
		}
	}
}

func TestTenantURL(t *testing.T) {
	for _, tc := range []struct{ claimURL, want string }{
		{"", ""},
		{"not a url", ""}, // parses, but has no host
		{"%zz", ""},       // parse error
		{"https://app.example.com/claim", "https://app.example.com/login?tenant=acme"},
	} {
		h := &Handler{cfg: &Config{ClaimURL: tc.claimURL}}
		if got := h.tenantURL("acme"); got != tc.want {
			t.Errorf("tenantURL with ClaimURL %q = %q, want %q", tc.claimURL, got, tc.want)
		}
	}
}

func TestHostStatusReadError(t *testing.T) {
	status, logs := kuHostStatus(t, errors.New("db down"))
	if status != "unknown" {
		t.Errorf("read error: status %q, want unknown", status)
	}
	if !strings.Contains(logs, "checkout: tenant host status read") {
		t.Errorf("read error: want the warn in the log, got %q", logs)
	}
}

func TestHostStatusNotFoundIsQuiet(t *testing.T) {
	status, logs := kuHostStatus(t, store.ErrNotFound)
	if status != "unknown" {
		t.Errorf("no row: status %q, want unknown", status)
	}
	if logs != "" {
		t.Errorf("no row: want no warn, got %q", logs)
	}
}

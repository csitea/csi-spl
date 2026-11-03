package payments

import (
	"bytes"
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

// paypal-cert-url arrives from the network and validatePayPalCertURL is the
// SSRF boundary in front of fetchCert (refactor round 22, row 08: no test
// named either). Every refusal must be ErrSigBad, the one failure value.

func TestValidatePayPalCertURLAccepts(t *testing.T) {
	for _, u := range []string{
		"https://paypal.com/x",
		"https://api.paypal.com/x",
		"HTTPS://API.PAYPAL.COM/x",
	} {
		if err := validatePayPalCertURL(u); err != nil {
			t.Errorf("validatePayPalCertURL(%q) = %v, want nil", u, err)
		}
	}
}

func TestValidatePayPalCertURLRefuses(t *testing.T) {
	for _, u := range []string{
		"http://paypal.com/x",
		"https://notpaypal.com/x",
		"https://paypal.com.example.com/x",
		"https://paypal.com@example.com/x",
		"https://example.com/?h=paypal.com",
		"https://paypal.com/%zz",
	} {
		if err := validatePayPalCertURL(u); !errors.Is(err, ErrSigBad) {
			t.Errorf("validatePayPalCertURL(%q) = %v, want ErrSigBad", u, err)
		}
	}
}

// pcServe starts a local server that answers every request with status and
// body; no real network is reached.
func pcServe(t *testing.T, status int, body []byte) *httptest.Server {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(status)
		_, _ = w.Write(body)
	}))
	t.Cleanup(srv.Close)
	return srv
}

// pcFetch runs fetchCert with the default client (HTTPClient nil).
func pcFetch(t *testing.T, url string) ([]byte, error) {
	t.Helper()
	return (&PayPalVerifier{}).fetchCert(context.Background(), url)
}

func TestFetchCertReturnsBodyOn200(t *testing.T) {
	want := []byte("-----BEGIN CERTIFICATE-----\nnot-a-real-key\n")
	got, err := pcFetch(t, pcServe(t, http.StatusOK, want).URL+"/cert.pem")
	if err != nil || !bytes.Equal(got, want) {
		t.Fatalf("fetchCert = %q, %v; want %q, nil", got, err, want)
	}
}

func TestFetchCertRefuses404(t *testing.T) {
	got, err := pcFetch(t, pcServe(t, http.StatusNotFound, []byte("nope")).URL)
	if !errors.Is(err, ErrSigBad) || got != nil {
		t.Fatalf("fetchCert = %q, %v; want nil, ErrSigBad", got, err)
	}
}

func TestFetchCertRefusesClosedServer(t *testing.T) {
	srv := httptest.NewServer(http.NotFoundHandler())
	url := srv.URL
	srv.Close()
	got, err := pcFetch(t, url)
	if !errors.Is(err, ErrSigBad) || got != nil {
		t.Fatalf("fetchCert = %q, %v; want nil, ErrSigBad", got, err)
	}
}

func TestFetchCertCutsBodyAt1MiB(t *testing.T) {
	const limit = 1 << 20
	got, err := pcFetch(t, pcServe(t, http.StatusOK, bytes.Repeat([]byte("a"), limit+4096)).URL)
	if err != nil || len(got) != limit {
		t.Fatalf("fetchCert = %d bytes, %v; want %d, nil", len(got), err, limit)
	}
}

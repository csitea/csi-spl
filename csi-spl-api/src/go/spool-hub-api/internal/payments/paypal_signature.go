package payments

// Copied from csi-rel csi-rel-api/src/internal/webhooks/paypal_signature.go
// (tree e4612828). OFF by default with the PayPal driver; not live-tested.

import (
	"context"
	"crypto"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base64"
	"encoding/pem"
	"fmt"
	"hash/crc32"
	"io"
	"net/http"
	"net/url"
	"strings"
	"sync"
	"time"
)

// ----------------------------------------------------------------------------
// PayPal — offline webhook signature verification (050 T006)
// ----------------------------------------------------------------------------
//
// PayPal signs each webhook with the merchant's rotating signing certificate.
// Verification is OFFLINE (no call back to PayPal on the request path, so a
// PayPal outage cannot stall our webhook endpoint):
//
//	message   = transmissionId|transmissionTime|webhookId|crc32(rawBody)
//	signature = base64( RSA-SHA256( message, paypal_private_key ) )
//	pubkey    = leaf certificate served at paypal-cert-url
//
// Same failure contract as VerifyStripe/VerifyPaytrail: every failure mode
// collapses to ErrSigBad, so a caller can never leak WHY a forgery was
// rejected (payment-webhook.md §Response codes).

// PayPalHeaders is the transmission metadata PayPal sends alongside the body.
// Field names map to the paypal-* HTTP headers.
type PayPalHeaders struct {
	TransmissionID   string // paypal-transmission-id
	TransmissionTime string // paypal-transmission-time
	TransmissionSig  string // paypal-transmission-sig (base64)
	CertURL          string // paypal-cert-url
	AuthAlgo         string // paypal-auth-algo (SHA256withRSA)
}

// PayPalHeadersFrom pulls the transmission metadata off a request header getter
// (http.Header.Get). Kept separate from the handler so tests can build headers
// without a request.
func PayPalHeadersFrom(get func(string) string) PayPalHeaders {
	return PayPalHeaders{
		TransmissionID:   get("paypal-transmission-id"),
		TransmissionTime: get("paypal-transmission-time"),
		TransmissionSig:  get("paypal-transmission-sig"),
		CertURL:          get("paypal-cert-url"),
		AuthAlgo:         get("paypal-auth-algo"),
	}
}

// paypalAuthAlgo is the only algorithm PayPal uses (and the only one we accept
// — an attacker must not be able to downgrade us by naming a weaker one).
const paypalAuthAlgo = "SHA256withRSA"

// paypalCertHost / paypalCertHostSuffix bound where a signing certificate may
// be fetched from. paypal-cert-url is attacker-controlled input: without this
// allowlist a forged webhook could point us at a certificate the attacker owns
// (and turn the API into an SSRF probe).
const (
	paypalCertHost       = "paypal.com"
	paypalCertHostSuffix = ".paypal.com"
)

// paypalTransmissionTolerance bounds replay of a captured-and-resent webhook.
// PayPal's transmission time is RFC 3339. Events older than this are refused;
// the webhook_events_seen dedup covers replays inside the window.
const paypalTransmissionTolerance = 5 * time.Minute

// PayPalVerifier verifies PayPal webhook signatures and caches the signing
// certificates it fetched. The zero value is not usable — WebhookID must be
// set (it is part of the signed message, so an empty id can never verify).
type PayPalVerifier struct {
	// WebhookID is the id PayPal assigned to OUR webhook subscription
	// (PAYPAL_WEBHOOK_ID). Empty → every verification fails closed.
	WebhookID string
	// Fetch overrides certificate retrieval (tests). Nil → HTTPS GET with the
	// *.paypal.com host allowlist.
	Fetch func(ctx context.Context, certURL string) ([]byte, error)
	// HTTPClient is optional; nil → http.Client with a 10s timeout.
	HTTPClient *http.Client
	// Now is injectable for replay-window tests; nil → time.Now.
	Now func() time.Time

	mu    sync.Mutex
	certs map[string]*rsa.PublicKey
}

// Verify checks the PayPal transmission signature over body.
// Returns nil on success, ErrSigBad on every failure.
func (v *PayPalVerifier) Verify(ctx context.Context, h PayPalHeaders, body string) error {
	if v == nil || strings.TrimSpace(v.WebhookID) == "" {
		return ErrSigBad
	}
	if h.TransmissionID == "" || h.TransmissionTime == "" || h.TransmissionSig == "" || h.CertURL == "" {
		return ErrSigBad
	}
	// An empty auth-algo header is tolerated (PayPal always sends it, but the
	// signature itself is the real gate); a DIFFERENT algo is not.
	if h.AuthAlgo != "" && !strings.EqualFold(strings.TrimSpace(h.AuthAlgo), paypalAuthAlgo) {
		return ErrSigBad
	}

	ts, err := time.Parse(time.RFC3339, strings.TrimSpace(h.TransmissionTime))
	if err != nil {
		return ErrSigBad
	}
	now := time.Now()
	if v.Now != nil {
		now = v.Now()
	}
	if d := now.Sub(ts); d > paypalTransmissionTolerance || d < -paypalTransmissionTolerance {
		return ErrSigBad
	}

	sig, err := base64.StdEncoding.DecodeString(strings.TrimSpace(h.TransmissionSig))
	if err != nil || len(sig) == 0 {
		return ErrSigBad
	}

	pub, err := v.publicKey(ctx, h.CertURL)
	if err != nil {
		return ErrSigBad
	}

	digest := sha256.Sum256([]byte(PayPalSignedMessage(h.TransmissionID, h.TransmissionTime, v.WebhookID, body)))
	if err := rsa.VerifyPKCS1v15(pub, crypto.SHA256, digest[:], sig); err != nil {
		return ErrSigBad
	}
	return nil
}

// PayPalSignedMessage builds the exact string PayPal signs:
// transmissionId|transmissionTime|webhookId|crc32(rawBody).
// Exported so the test suite signs with the identical construction and drift
// between sign and verify is mechanically impossible (as with SignStripe).
func PayPalSignedMessage(transmissionID, transmissionTime, webhookID, body string) string {
	return fmt.Sprintf("%s|%s|%s|%d",
		transmissionID, transmissionTime, webhookID,
		crc32.ChecksumIEEE([]byte(body)))
}

// publicKey returns the RSA public key of the leaf certificate at certURL,
// fetching + caching it on first use.
func (v *PayPalVerifier) publicKey(ctx context.Context, certURL string) (*rsa.PublicKey, error) {
	v.mu.Lock()
	if key, ok := v.certs[certURL]; ok && key != nil {
		v.mu.Unlock()
		return key, nil
	}
	v.mu.Unlock()

	if err := validatePayPalCertURL(certURL); err != nil {
		return nil, err
	}

	fetch := v.Fetch
	if fetch == nil {
		fetch = v.fetchCert
	}
	raw, err := fetch(ctx, certURL)
	if err != nil {
		return nil, err
	}
	key, err := rsaPublicKeyFromPEM(raw)
	if err != nil {
		return nil, err
	}

	v.mu.Lock()
	if v.certs == nil {
		v.certs = map[string]*rsa.PublicKey{}
	}
	v.certs[certURL] = key
	v.mu.Unlock()
	return key, nil
}

// validatePayPalCertURL enforces https + a paypal.com host. paypal-cert-url
// arrives from the network, so this is the SSRF boundary.
func validatePayPalCertURL(certURL string) error {
	u, err := url.Parse(strings.TrimSpace(certURL))
	if err != nil {
		return ErrSigBad
	}
	if !strings.EqualFold(u.Scheme, "https") {
		return ErrSigBad
	}
	host := strings.ToLower(u.Hostname())
	if host != paypalCertHost && !strings.HasSuffix(host, paypalCertHostSuffix) {
		return ErrSigBad
	}
	return nil
}

func (v *PayPalVerifier) fetchCert(ctx context.Context, certURL string) ([]byte, error) {
	cl := v.HTTPClient
	if cl == nil {
		cl = &http.Client{Timeout: 10 * time.Second}
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, certURL, nil)
	if err != nil {
		return nil, ErrSigBad
	}
	resp, err := cl.Do(req)
	if err != nil {
		return nil, ErrSigBad
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		return nil, ErrSigBad
	}
	raw, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20))
	if err != nil {
		return nil, ErrSigBad
	}
	return raw, nil
}

// rsaPublicKeyFromPEM extracts the RSA public key of the first CERTIFICATE
// block in a PEM chain.
func rsaPublicKeyFromPEM(raw []byte) (*rsa.PublicKey, error) {
	rest := raw
	for {
		var block *pem.Block
		block, rest = pem.Decode(rest)
		if block == nil {
			return nil, ErrSigBad
		}
		if block.Type != "CERTIFICATE" {
			continue
		}
		cert, err := x509.ParseCertificate(block.Bytes)
		if err != nil {
			return nil, ErrSigBad
		}
		key, ok := cert.PublicKey.(*rsa.PublicKey)
		if !ok {
			return nil, ErrSigBad
		}
		return key, nil
	}
}

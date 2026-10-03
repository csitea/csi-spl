package auth

import (
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"time"
)

// Both the OAuth state and the session cookie are `<b64url(json)>.<b64url(mac)>`
// signed with a subkey derived from SPOOL_HUB_AUTH_SESSION_KEY, one label per
// use, so a session can never be replayed as a state or vice versa.
const (
	labelState   = "spool-auth-state-v1"
	labelSession = "spool-auth-session-v1"
)

var (
	errBadToken     = errors.New("auth: malformed or forged token")
	errExpiredToken = errors.New("auth: token expired")
)

func subkey(key, label string) []byte {
	m := hmac.New(sha256.New, []byte(key))
	m.Write([]byte(label))
	return m.Sum(nil)
}

func signToken(key []byte, v any) (string, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return "", err
	}
	payload := base64.RawURLEncoding.EncodeToString(raw)
	m := hmac.New(sha256.New, key)
	m.Write([]byte(payload))
	return payload + "." + base64.RawURLEncoding.EncodeToString(m.Sum(nil)), nil
}

// openToken verifies the MAC before it decodes anything, then the expiry.
func openToken(key []byte, tok string, v interface{ expiry() int64 }, now time.Time) error {
	payload, sig, ok := strings.Cut(tok, ".")
	if !ok || payload == "" || sig == "" {
		return errBadToken
	}
	m := hmac.New(sha256.New, key)
	m.Write([]byte(payload))
	got, err := base64.RawURLEncoding.DecodeString(sig)
	if err != nil || !hmac.Equal(got, m.Sum(nil)) {
		return errBadToken
	}
	raw, err := base64.RawURLEncoding.DecodeString(payload)
	if err != nil || json.Unmarshal(raw, v) != nil {
		return errBadToken
	}
	if now.Unix() >= v.expiry() {
		return errExpiredToken
	}
	return nil
}

// statePayload rides the IdP round trip as `state`. The nonce is also set as
// an HttpOnly cookie on the browser that started the flow; the callback
// requires both to match, so a state lifted from another browser is useless.
type statePayload struct {
	Provider string `json:"p"`
	Nonce    string `json:"n"`
	Redirect string `json:"r,omitempty"` // same-site WUI path to land on
	Tenant   string `json:"t,omitempty"` // tenant the sign-in started from
	Exp      int64  `json:"e"`
}

func (s *statePayload) expiry() int64 { return s.Exp }

// Session is the signed session cookie's claims. It says who the person is;
// what they may read is the hub's decision (Registrar, tenant membership).
type Session struct {
	V        int    `json:"v"`
	Provider string `json:"p"`
	Subject  string `json:"sub"`
	Email    string `json:"email"`
	Name     string `json:"name,omitempty"`
	HumanID  string `json:"hum,omitempty"` // HUM-* from the Registrar, when wired
	Tenant   string `json:"t,omitempty"`
	IssuedAt int64  `json:"iat"`
	Exp      int64  `json:"exp"`
}

func (s *Session) expiry() int64 { return s.Exp }

// newNonce is 256 bits from crypto/rand (SOC-NFR-001).
func newNonce() (string, error) {
	b := make([]byte, 32)
	if _, err := rand.Read(b); err != nil {
		return "", err
	}
	return base64.RawURLEncoding.EncodeToString(b), nil
}

// safeRedirect keeps the post-login landing a same-site path: absolute URLs,
// protocol-relative "//host" and backslash tricks collapse to "/". So does any
// byte <= 0x20 or DEL: the WHATWG URL parser drops TAB/CR/LF, so "/\t/evil.com"
// resolves to host evil.com in the browser the native /login JSON hands it to
// (the WUI's rule, f0a9ce0a).
func safeRedirect(raw string) string {
	if raw == "" || !strings.HasPrefix(raw, "/") || strings.HasPrefix(raw, "//") {
		return "/"
	}
	for i := range len(raw) {
		if c := raw[i]; c <= 0x20 || c == 0x7f || c == '\\' {
			return "/"
		}
	}
	return raw
}

// validTenant accepts a DNS-label tenant id (the {tenant} of
// SPOOL_HUB_TENANT_HOST_PATTERN); anything else is dropped, not echoed.
func validTenant(t string) bool {
	if t == "" || len(t) > 63 || t[0] == '-' || t[len(t)-1] == '-' {
		return false
	}
	for i := range len(t) {
		c := t[i]
		if !(c >= 'a' && c <= 'z' || c >= '0' && c <= '9' || c == '-') {
			return false
		}
	}
	return true
}

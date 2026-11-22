package auth

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

// failingRevoker is a revocation store whose every call fails and counts.
type failingRevoker struct{ calls atomic.Int64 }

func (f *failingRevoker) RevokeSessions(context.Context, string, time.Time) error {
	f.calls.Add(1)
	return errors.New("store down")
}

func (f *failingRevoker) SessionRevocations(context.Context, time.Time) (map[string]time.Time, error) {
	f.calls.Add(1)
	return nil, errors.New("store down")
}

// C44 (spec 162 10.9, Q4 B), the auth half: HumanFromCookie names the person
// of a valid signed cookie without the store (every revocation call fails
// and none is made), and names nobody for a forged, expired, foreign-key,
// box (no HUM-*) or missing cookie.
func TestHumanFromCookieReadsNoStore(t *testing.T) {
	root := strings.Repeat("k", 32)
	cfg, err := LoadFrom("lde", map[string]string{
		"SPOOL_HUB_AUTH_PROVIDERS":            "google",
		"SPOOL_HUB_AUTH_SESSION_KEY":          root,
		"SPOOL_HUB_AUTH_APP_URL":              "http://wui.test",
		"SPOOL_HUB_AUTH_COOKIE_SECURE":        "false",
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID":     "gid",
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET": "gsecret",
		"SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI":  "http://login.test/api/v1/auth/google/callback",
	})
	if err != nil {
		t.Fatal(err)
	}
	now := time.Unix(1_800_000_000, 0)
	rev := &failingRevoker{}
	h := New(cfg, zerolog.Nop(), Options{Revocations: rev, Now: func() time.Time { return now }})
	seal := func(key []byte, s Session) string {
		tok, err := signToken(key, s)
		if err != nil {
			t.Fatal(err)
		}
		return tok
	}
	key := subkey(root, labelSession)
	live := Session{V: 1, Provider: "google", HumanID: "HUM-42", IssuedAt: now.Unix(), Exp: now.Add(time.Hour).Unix()}
	valid := seal(key, live)
	payload, _, _ := strings.Cut(valid, ".")
	expired := live
	expired.Exp = now.Add(-time.Second).Unix()
	box := live
	box.HumanID = ""
	for name, tc := range map[string]struct {
		cookie string // "" = no cookie
		want   string
	}{
		"valid":       {valid, "HUM-42"},
		"forged sig":  {payload + "." + strings.Repeat("A", 43), ""},
		"foreign key": {seal(subkey(strings.Repeat("x", 32), labelSession), live), ""},
		"state key":   {seal(subkey(root, labelState), live), ""},
		"expired":     {seal(key, expired), ""},
		"no human":    {seal(key, box), ""},
		"garbage":     {"not-a-token", ""},
		"no cookie":   {"", ""},
	} {
		r := httptest.NewRequest(http.MethodGet, "/v1/x", nil)
		if tc.cookie != "" {
			r.AddCookie(&http.Cookie{Name: cfg.CookieName, Value: tc.cookie})
		}
		if got := h.HumanFromCookie(r); got != tc.want {
			t.Errorf("%s: HumanFromCookie = %q, want %q", name, got, tc.want)
		}
	}
	if n := rev.calls.Load(); n != 0 {
		t.Fatalf("HumanFromCookie made %d revocation-store calls, want 0", n)
	}
	// The control: SessionFromRequest on the same valid cookie does read the
	// store (its revocation check), which is what the error path must avoid.
	r := httptest.NewRequest(http.MethodGet, "/v1/x", nil)
	r.AddCookie(&http.Cookie{Name: cfg.CookieName, Value: valid})
	h.SessionFromRequest(r)
	if rev.calls.Load() == 0 {
		t.Fatal("control: SessionFromRequest made no revocation-store call; the no-store claim above proves nothing")
	}
	var nilH *Handler
	if got := nilH.HumanFromCookie(r); got != "" {
		t.Fatalf("nil handler: %q", got)
	}
}

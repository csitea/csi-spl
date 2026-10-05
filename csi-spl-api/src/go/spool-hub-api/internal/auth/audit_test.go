package auth

import (
	"context"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"
)

func TestMaskIP(t *testing.T) {
	cases := map[string]string{
		"203.0.113.42":          "203.0.113.0/24",
		"8.8.8.8":               "8.8.8.0/24",
		"2001:db8:1234:5678::1": "2001:db8:1234::/48",
		"":                      "",
		"  ":                    "",
		"not-an-ip":             "",
	}
	for in, want := range cases {
		if got := maskIP(in); got != want {
			t.Errorf("maskIP(%q) = %q, want %q", in, got, want)
		}
	}
}

func TestCoarseUA(t *testing.T) {
	cases := map[string]string{
		"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36":               "Chrome on Windows",
		"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15":         "Safari on macOS",
		"Mozilla/5.0 (X11; Linux x86_64; rv:120.0) Gecko/20100101 Firefox/120.0":                                                        "Firefox on Linux",
		"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36 Edg/120":       "Edge on Windows",
		"Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1 (KHTML, like Gecko) Version/17.0 Mobile Safari/604.1": "Safari on iOS",
		"": "",
	}
	for in, want := range cases {
		if got := coarseUA(in); got != want {
			t.Errorf("coarseUA(%q) = %q, want %q", in, got, want)
		}
	}
}

type fakeRecorder struct{ got []string }

type seatSet map[string]bool // "hum|tenant" -> a live seat

func (m seatSet) Member(_ context.Context, hum, tenant string) (bool, error) {
	return m[hum+"|"+tenant], nil
}

func (f *fakeRecorder) RecordAuthEvent(_ context.Context, tenant, hum, kind, method, ip, ua string, _ time.Time) error {
	f.got = append(f.got, strings.Join([]string{tenant, hum, kind, method, ip, ua}, "|"))
	return nil
}

// TestRecordAuth: an event carries the masked IP + coarse UA, and is skipped
// when auditing is off or the workspace / human is unknown (owner privacy rule).
func TestRecordAuth(t *testing.T) {
	f := &fakeRecorder{}
	h := &Handler{audit: f, hops: 0, now: func() time.Time { return time.Unix(0, 0) }, log: zerolog.Nop(),
		members: seatSet{"HUM-9|t1": true}}
	r := httptest.NewRequest("POST", "/", nil)
	r.RemoteAddr = "203.0.113.42:5555"
	r.Header.Set("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) Chrome/120.0.0.0 Safari/537.36")

	h.recordAuth(r, "t1", "HUM-9", "sign_in", "google")
	if len(f.got) != 1 || f.got[0] != "t1|HUM-9|sign_in|google|203.0.113.0/24|Chrome on Windows" {
		t.Fatalf("recordAuth = %v", f.got)
	}
	// skipped: no workspace, no human, or auditing off — never a partial row
	h.recordAuth(r, "", "HUM-9", "sign_in", "google")
	h.recordAuth(r, "t1", "", "sign_in", "google")
	(&Handler{audit: nil, now: h.now, log: zerolog.Nop()}).recordAuth(r, "t1", "HUM-9", "sign_in", "x")
	if len(f.got) != 1 {
		t.Fatalf("recordAuth recorded a skipped event: %v", f.got)
	}
}

// TestLogoutStaleTenantRecordsNothing (s077 L2): a person whose seat in tB is
// gone but whose cookie still says t=tB signs out: no sign_out row lands in
// tB's activity log. CONTROL: a live seat (tA) still records its sign_out.
func TestLogoutStaleTenantRecordsNothing(t *testing.T) {
	for _, tc := range []struct {
		tenant string
		want   int
	}{{"tB", 0}, {"tA", 1}} {
		f := &fakeRecorder{}
		key := []byte("0123456789abcdef0123456789abcdef")
		h := &Handler{audit: f, now: time.Now, log: zerolog.Nop(), sessionKey: key,
			cfg: &Config{CookieName: "spool_session"}, members: seatSet{"HUM-9|tA": true}}
		tok, err := signToken(key, Session{V: 1, HumanID: "HUM-9", Tenant: tc.tenant, Provider: "google",
			Exp: time.Now().Add(time.Hour).Unix()})
		if err != nil {
			t.Fatal(err)
		}
		r := httptest.NewRequest("POST", "/api/v1/auth/logout", nil)
		r.Header.Set("Cookie", "spool_session="+tok)
		w := httptest.NewRecorder()
		h.logout(w, r)
		if w.Code != http.StatusNoContent {
			t.Fatalf("logout t=%s = %d, want 204", tc.tenant, w.Code)
		}
		if len(f.got) != tc.want {
			t.Errorf("logout t=%s recorded %d sign_out rows, want %d: %v", tc.tenant, len(f.got), tc.want, f.got)
		}
	}
}

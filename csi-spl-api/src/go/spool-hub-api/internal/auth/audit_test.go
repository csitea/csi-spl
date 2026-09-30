package auth

import (
	"context"
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

func (f *fakeRecorder) RecordAuthEvent(_ context.Context, tenant, hum, kind, method, ip, ua string, _ time.Time) error {
	f.got = append(f.got, strings.Join([]string{tenant, hum, kind, method, ip, ua}, "|"))
	return nil
}

// TestRecordAuth: an event carries the masked IP + coarse UA, and is skipped
// when auditing is off or the workspace / human is unknown (owner privacy rule).
func TestRecordAuth(t *testing.T) {
	f := &fakeRecorder{}
	h := &Handler{audit: f, hops: 0, now: func() time.Time { return time.Unix(0, 0) }, log: zerolog.Nop()}
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

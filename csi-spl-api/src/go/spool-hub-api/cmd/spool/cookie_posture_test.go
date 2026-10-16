package main

import (
	"bytes"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// SPL-2152: a hub whose sign-in is on and whose session cookie is not Secure
// off localhost says so at start; a local stack and a Secure cookie stay quiet.
func TestLogCookiePosture(t *testing.T) {
	for _, tc := range []struct {
		name, setting, appURL string
		native, warn          bool
	}{
		{"public http, explicit false", "false", "http://203.0.113.7:8080", true, true},
		{"public https, explicit false", "false", "https://chat.example.test", true, true},
		{"public http, auto", "auto", "http://chat.example.test", true, false},
		{"localhost, explicit false", "false", "http://localhost:8080", true, false},
		{"sign-in off", "false", "http://203.0.113.7:8080", false, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			ac, err := auth.LoadFrom("lde", map[string]string{
				"SPOOL_HUB_AUTH_COOKIE_SECURE": tc.setting, "SPOOL_HUB_AUTH_APP_URL": tc.appURL})
			if err != nil {
				t.Fatal(err)
			}
			var buf bytes.Buffer
			logCookiePosture(zerolog.New(&buf), ac, &auth.NativeConfig{Enabled: tc.native})
			got := strings.Contains(buf.String(), `"level":"warn"`) && strings.Contains(buf.String(), "auth.cookie_not_secure")
			if got != tc.warn {
				t.Fatalf("warn = %v, want %v; log: %s", got, tc.warn, buf.String())
			}
		})
	}
}

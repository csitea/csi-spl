package main

import (
	"bytes"
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
)

// r16-10: gcalConnect's wiring guards. Each guard keeps Google (and the
// Sealer) nil, so connect answers 503, and says why in one log line. No
// network: the KMS client is built from a credentials file that is either
// missing or an authorized_user stub, which the client reads without a call.

func gcalOnHub() *config.Hub {
	return &config.Hub{
		GcalWorkspaces: []string{"t1"}, GcalScopes: "openid email",
		GcalAuthURL: "https://auth.invalid/o", GcalTokenURL: "https://auth.invalid/t",
		GcalRevokeURL: "https://auth.invalid/r", GcalUserinfoURL: "https://auth.invalid/u",
		GcalCalendarBase: "https://cal.invalid/v3/", TenantHostPattern: "{tenant}.example.com",
		MarketingKMSKey: "projects/p/locations/l/keyRings/r/cryptoKeys/k",
	}
}

func gcalOnAuth() *auth.Config {
	return &auth.Config{AppURL: " https://app.example.com/ ", GoogleClientID: "cid", GoogleClientSecret: "r16-10-not-a-secret",
		StateCookieName: "st", CookieDomain: "example.com", CookieSecure: true}
}

// adcFile points Application Default Credentials at a temp file: body ""
// leaves it missing (the KMS client fails), else it is written.
func adcFile(t *testing.T, body string) {
	t.Helper()
	p := filepath.Join(t.TempDir(), "adc.json")
	if body != "" {
		if err := os.WriteFile(p, []byte(body), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	t.Setenv("GOOGLE_APPLICATION_CREDENTIALS", p)
}

const adcStub = `{"type":"authorized_user","client_id":"r16-10","client_secret":"r16-10","refresh_token":"r16-10"}`

func TestGcalConnectOffWithoutWorkspaces(t *testing.T) {
	var buf bytes.Buffer
	if g := gcalConnect(context.Background(), &config.Hub{}, gcalOnAuth(), zerolog.New(&buf)); g != nil {
		t.Fatalf("gcalConnect = %+v, want nil with no workspace", g)
	}
	if !strings.Contains(buf.String(), "gcal: off, no workspace listed") {
		t.Fatalf("log = %q", buf.String())
	}
}

func TestGcalConnectNotConfigured(t *testing.T) {
	cases := []struct {
		name string
		hub  func(*config.Hub)
		auth func(*auth.Config)
		adc  string
		want string
	}{
		{"no client id", nil, func(a *auth.Config) { a.GoogleClientID = " " }, adcStub,
			`"app_url":true,"err":"gcal: not configured: 1 field(s) empty","message":"gcal: not configured, connect answers 503"`},
		{"no app url", nil, func(a *auth.Config) { a.AppURL = "/" }, adcStub,
			`"app_url":false,"err":"","message":"gcal: not configured, connect answers 503"`},
		{"no kms key", func(h *config.Hub) { h.MarketingKMSKey = " " }, nil, adcStub,
			"gcal: not configured, no KMS key, connect answers 503"},
		{"no kms client", nil, nil, "",
			"gcal: not configured, no KMS client, connect answers 503"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			adcFile(t, tc.adc)
			hc, ac := gcalOnHub(), gcalOnAuth()
			if tc.hub != nil {
				tc.hub(hc)
			}
			if tc.auth != nil {
				tc.auth(ac)
			}
			var buf bytes.Buffer
			g := gcalConnect(context.Background(), hc, ac, zerolog.New(&buf))
			if g == nil {
				t.Fatal("gcalConnect = nil, want the routes mounted")
			}
			if g.Google != nil || g.Sealer != nil {
				t.Fatalf("Google %v / Sealer %v, want both nil (connect answers 503)", g.Google, g.Sealer)
			}
			if !strings.Contains(buf.String(), tc.want) {
				t.Fatalf("log = %q, want %q", buf.String(), tc.want)
			}
		})
	}
}

func TestGcalConnectOn(t *testing.T) {
	adcFile(t, adcStub)
	hc := gcalOnHub()
	hc.WUITenantHosts, hc.WUIApexTenant = true, "t1"
	var buf bytes.Buffer
	g := gcalConnect(context.Background(), hc, gcalOnAuth(), zerolog.New(&buf))
	if g == nil || g.Google == nil || g.Sealer == nil {
		t.Fatalf("gcalConnect = %+v, want Google and Sealer set; log %q", g, buf.String())
	}
	if g.CookieName != "st" || g.CookieDomain != "example.com" || !g.CookieSecure || len(g.Workspaces) != 1 {
		t.Fatalf("cookie / workspaces wiring = %+v", g)
	}
	want := `"workspaces":1,"redirect_uri":"https://app.example.com` + hub.GcalCallbackPath + `","message":"gcal: on"`
	if !strings.Contains(buf.String(), want) {
		t.Fatalf("log = %q, want %q", buf.String(), want)
	}
	if strings.Contains(buf.String(), "r16-10-not-a-secret") {
		t.Fatalf("log leaks the client secret: %q", buf.String())
	}
}

func TestErrText(t *testing.T) {
	if got := errText(nil); got != "" {
		t.Fatalf("errText(nil) = %q, want empty", got)
	}
	if got := errText(errors.New("boom")); got != "boom" {
		t.Fatalf("errText = %q, want boom", got)
	}
}

package auth_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/077 T011 (FR-007): GET session answers a demo visitor no email and
// its pseudonym, never the IdP name the cookie carries, and PUT preferences
// display_name is 403 pseudonym. CONTROL: a real member (bootstrap owner of
// another workspace) gets its email and may rename; on the old code the
// visitor's session carried the email and the IdP name. On memory and, with
// SPOOL_TEST_PG_DSN, Postgres.
func TestDemoSessionPseudonym(t *testing.T) {
	for name, st := range fenceStores(t) {
		t.Run(name, func(t *testing.T) {
			ctx, now := context.Background(), time.Now()
			id := func() string {
				b := make([]byte, 4)
				rand.Read(b) //nolint:errcheck
				return hex.EncodeToString(b)
			}
			demo, other := "t"+id(), "t"+id()
			for _, tid := range []string{demo, other} {
				pub, _, _ := ed25519.GenerateKey(nil)
				if err := st.CreateTenant(ctx, store.Tenant{ID: tid, RootPubKey: pub}); err != nil {
					t.Fatal(err)
				}
			}
			hooks := store.AuthHooks{H: st, Policy: store.AdmitPolicy{BootstrapOwner: true,
				OpenWorkspace: demo, OpenProviders: []string{"google"}}}
			cfg, err := auth.LoadFrom("lde", map[string]string{"SPOOL_HUB_AUTH_SESSION_KEY": strings.Repeat("k", 32),
				"SPOOL_HUB_AUTH_APP_URL": "http://app.example.test", "SPOOL_HUB_AUTH_COOKIE_SECURE": "false"})
			if err != nil {
				t.Fatal(err)
			}
			h := auth.New(cfg, zerolog.Nop(), auth.Options{Registrar: hooks, Membership: hooks,
				Preferences: hooks, DemoWorkspace: demo})
			nc, err := auth.LoadNativeFrom("lde", map[string]string{"SPOOL_HUB_AUTH_NATIVE_ENABLED": "true"})
			if err != nil {
				t.Fatal(err)
			}
			if err := h.EnableNative(nc, auth.NativeDeps{Store: auth.NewMemoryCredStore()}); err != nil {
				t.Fatal(err)
			}

			type seen struct {
				code        int
				email, name string
				raw         string
			}
			signIn := func(local, tenant string) (string, *http.Cookie) {
				t.Helper()
				who := auth.Identity{Provider: "google", Subject: local + "-" + id(), Name: "FirstName LastName"}
				who.Email = who.Subject + "@example.com"
				hum, err := hooks.Register(ctx, who, tenant)
				if err != nil {
					t.Fatalf("register %s: %v", local, err)
				}
				return hum, auth.MintSessionCookie(h, auth.Session{V: 1, Provider: who.Provider, Subject: who.Subject,
					Email: who.Email, Name: who.Name, HumanID: hum, Tenant: tenant,
					IssuedAt: now.Unix(), Exp: now.Add(time.Hour).Unix()})
			}
			session := func(ck *http.Cookie) seen {
				t.Helper()
				code, body := fenceCall(h, ck, http.MethodGet, "/api/v1/auth/session", "")
				var out struct {
					Email string `json:"email"`
					Name  string `json:"name"`
				}
				if err := json.Unmarshal([]byte(body), &out); err != nil {
					t.Fatalf("decode session: %v (%s)", err, body)
				}
				return seen{code, out.Email, out.Name, body}
			}

			hv, cv := signIn("visitor", demo)
			got := session(cv)
			if got.code != http.StatusOK || got.email != "" || got.name != store.DemoPseudonym(hv) {
				t.Fatalf("demo session: %d email %q name %q, want no email and %q: %s",
					got.code, got.email, got.name, store.DemoPseudonym(hv), got.raw)
			}
			if strings.Contains(got.raw, "@example.com") || strings.Contains(got.raw, "FirstName LastName") {
				t.Fatalf("demo session carries the email or the IdP name: %s", got.raw)
			}
			if code, body := fenceCall(h, cv, http.MethodPut, "/api/v1/auth/preferences", `{"display_name":"FirstName LastName"}`); code != http.StatusForbidden || !strings.Contains(body, `"pseudonym"`) {
				t.Fatalf("demo rename: %d %s, want 403 pseudonym", code, body)
			}

			// CONTROL: a real member keeps its email and its own name.
			_, co := signIn("owner", other)
			if got := session(co); got.code != http.StatusOK || got.email == "" || got.name != "FirstName LastName" {
				t.Fatalf("CONTROL member session: %d email %q name %q: %s", got.code, got.email, got.name, got.raw)
			}
			if code, body := fenceCall(h, co, http.MethodPut, "/api/v1/auth/preferences", `{"display_name":"Chosen Name"}`); code != http.StatusOK {
				t.Fatalf("CONTROL member rename: %d %s", code, body)
			}
		})
	}
}

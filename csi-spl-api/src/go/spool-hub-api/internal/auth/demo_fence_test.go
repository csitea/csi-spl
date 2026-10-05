package auth_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/077 §3.8, T015: a demo_user seat outside the open demo workspace (a
// fenced seat: the demo id changed, or the demo is off) is no membership to
// the hub, and auth names its tenant nowhere: not in GET session's tenants,
// not as active_tenant, and POST tenant into it answers what a workspace with
// no seat answers (403 not_member). On memory and, with SPOOL_TEST_PG_DSN,
// Postgres.
// CONTROLS: the same human's developer seat and open demo seat are listed and
// switched into; with the fence removed (Handler.fenced false) this fails.

// fenceStore is what the test seeds: tenants, invites, admissions.
type fenceStore interface {
	store.Humans
	CreateTenant(ctx context.Context, t store.Tenant) error
}

func fenceStores(t *testing.T) map[string]fenceStore {
	t.Helper()
	out := map[string]fenceStore{"memory": store.NewMemory()}
	if dsn := os.Getenv("SPOOL_TEST_PG_DSN"); dsn != "" {
		pg, err := store.OpenPostgres(context.Background(), dsn)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(pg.Close)
		out["postgres"] = pg
	}
	return out
}

// fenceSeats: one human, a demo_user seat in demo and in fenced, a developer
// seat in dev. Fresh ids per run, so a shared Postgres never collides.
type fenceSeats struct {
	hum, demo, fenced, dev string
}

func seedFenceSeats(t *testing.T, st fenceStore) fenceSeats {
	t.Helper()
	ctx, now := context.Background(), time.Now()
	id := func() string {
		b := make([]byte, 4)
		rand.Read(b) //nolint:errcheck
		return hex.EncodeToString(b)
	}
	f := fenceSeats{demo: "t" + id(), fenced: "t" + id(), dev: "t" + id()}
	who := store.Identity{Provider: "google", Subject: "fence-" + id()}
	who.Email = who.Subject + "@example.com"
	for tid, role := range map[string]string{f.demo: rbac.DemoUser, f.fenced: rbac.DemoUser, f.dev: rbac.Developer} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := st.CreateTenant(ctx, store.Tenant{ID: tid, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
		if err := st.PutInvite(ctx, store.Invite{TenantID: tid, Email: who.Email, Role: role,
			InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
			t.Fatal(err)
		}
		hum, err := st.Admit(ctx, who, tid, store.AdmitPolicy{}, now)
		if err != nil {
			t.Fatalf("admit to %s: %v", tid, err)
		}
		f.hum = hum
	}
	return f
}

// fenceHandler is a store-backed auth handler with demo as the open demo
// workspace ("" = the demo is off) and a session cookie of f.hum in tenant.
func fenceHandler(t *testing.T, st fenceStore, demo string, f fenceSeats, tenant string) (*auth.Handler, *http.Cookie) {
	t.Helper()
	cfg, err := auth.LoadFrom("lde", map[string]string{"SPOOL_HUB_AUTH_SESSION_KEY": strings.Repeat("k", 32),
		"SPOOL_HUB_AUTH_APP_URL": "http://app.example.test", "SPOOL_HUB_AUTH_COOKIE_SECURE": "false"})
	if err != nil {
		t.Fatal(err)
	}
	hooks := store.AuthHooks{H: st}
	h := auth.New(cfg, zerolog.Nop(), auth.Options{Membership: hooks, DemoWorkspace: demo})
	nc, err := auth.LoadNativeFrom("lde", map[string]string{"SPOOL_HUB_AUTH_NATIVE_ENABLED": "true"})
	if err != nil {
		t.Fatal(err)
	}
	if err := h.EnableNative(nc, auth.NativeDeps{Store: auth.NewMemoryCredStore()}); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	return h, auth.MintSessionCookie(h, auth.Session{V: 1, Provider: "google", Subject: "s", HumanID: f.hum,
		Tenant: tenant, IssuedAt: now.Unix(), Exp: now.Add(time.Hour).Unix()})
}

// fenceCall runs one request on h with the cookie: the code and the body.
func fenceCall(h *auth.Handler, ck *http.Cookie, method, path, body string) (int, string) {
	req := httptest.NewRequest(method, path, strings.NewReader(body))
	req.Header.Set("Content-Type", "application/json")
	req.AddCookie(ck)
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	return rec.Code, rec.Body.String()
}

// sessionTenantIDs is GET session's tenants and active_tenant.
func sessionTenantIDs(t *testing.T, body string) (map[string]bool, string) {
	t.Helper()
	var out struct {
		Active  *string           `json:"active_tenant"`
		Tenants []auth.TenantRole `json:"tenants"`
	}
	if err := json.Unmarshal([]byte(body), &out); err != nil {
		t.Fatalf("decode session: %v (%s)", err, body)
	}
	ids := map[string]bool{}
	for _, r := range out.Tenants {
		ids[r.TenantID] = true
	}
	active := ""
	if out.Active != nil {
		active = *out.Active
	}
	return ids, active
}

func TestFencedDemoSeatNamesNoTenant(t *testing.T) {
	for name, st := range fenceStores(t) {
		t.Run(name, func(t *testing.T) {
			f := seedFenceSeats(t, st)
			h, ck := fenceHandler(t, st, f.demo, f, f.demo)
			code, body := fenceCall(h, ck, http.MethodGet, "/api/v1/auth/session", "")
			ids, active := sessionTenantIDs(t, body)
			if code != http.StatusOK || !ids[f.demo] || !ids[f.dev] || active != f.demo {
				t.Fatalf("CONTROL: session lists %v active %q, want the demo and the dev seat: %d %s", ids, active, code, body)
			}
			if strings.Contains(body, f.fenced) {
				t.Errorf("GET session names the fenced seat's tenant %s: %s", f.fenced, body)
			}
			for _, tid := range []string{f.dev, f.demo} {
				if code, body := fenceCall(h, ck, http.MethodPost, "/api/v1/auth/tenant", `{"tenant":"`+tid+`"}`); code != http.StatusOK {
					t.Errorf("CONTROL: switch into the seat in %s: %d %s", tid, code, body)
				}
			}
			code, body = fenceCall(h, ck, http.MethodPost, "/api/v1/auth/tenant", `{"tenant":"`+f.fenced+`"}`)
			_, none := fenceCall(h, ck, http.MethodPost, "/api/v1/auth/tenant", `{"tenant":"tnoseat00"}`)
			if code != http.StatusForbidden || body != none {
				t.Errorf("switch into the fenced seat: %d %s, want the no-seat answer %s", code, body, none)
			}
		})
	}
}

// The demo off ("" workspace) fences every demo_user seat; a session whose
// `t` still names one has no active tenant, and its fallback is the one
// unfenced seat.
func TestDemoOffFencesEveryDemoSeat(t *testing.T) {
	for name, st := range fenceStores(t) {
		t.Run(name, func(t *testing.T) {
			f := seedFenceSeats(t, st)
			h, ck := fenceHandler(t, st, "", f, f.fenced)
			code, body := fenceCall(h, ck, http.MethodGet, "/api/v1/auth/session", "")
			ids, active := sessionTenantIDs(t, body)
			if code != http.StatusOK || len(ids) != 1 || !ids[f.dev] {
				t.Fatalf("session lists %v, want only the dev seat: %d %s", ids, code, body)
			}
			if active != "" {
				t.Errorf("active_tenant %q from a fenced `t`, want none", active)
			}
			for _, tid := range []string{f.demo, f.fenced} {
				if code, body := fenceCall(h, ck, http.MethodPost, "/api/v1/auth/tenant", `{"tenant":"`+tid+`"}`); code != http.StatusForbidden {
					t.Errorf("demo off, switch into the demo seat in %s: %d %s", tid, code, body)
				}
			}
			now := time.Now()
			ck = auth.MintSessionCookie(h, auth.Session{V: 1, Provider: "google", Subject: "s", HumanID: f.hum,
				IssuedAt: now.Unix(), Exp: now.Add(time.Hour).Unix()})
			_, body = fenceCall(h, ck, http.MethodGet, "/api/v1/auth/session", "")
			if _, active = sessionTenantIDs(t, body); active != f.dev {
				t.Errorf("no `t`: active_tenant %q, want the one unfenced seat %s", active, f.dev)
			}
		})
	}
}

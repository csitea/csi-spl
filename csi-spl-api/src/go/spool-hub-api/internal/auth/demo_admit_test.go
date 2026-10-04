package auth_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"net/http/httptest"
	"net/url"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/077 T007 through the real sign-in: a Google visitor naming the demo
// workspace lands with a session whose tenant IS the demo workspace (the
// self.keys check reads the role there) and a demo_user seat; the same
// visitor naming another workspace, or the demo with the flag off, is
// refused with no session.
func TestStoreBackedOpenDemoAdmission(t *testing.T) {
	ctx := context.Background()
	newStore := func(t *testing.T) *store.Memory {
		st := store.NewMemory()
		for _, id := range []string{"t1", "demo"} {
			pub, _, _ := ed25519.GenerateKey(nil)
			if err := st.CreateTenant(ctx, store.Tenant{ID: id, RootPubKey: pub}); err != nil {
				t.Fatal(err)
			}
		}
		if _, err := st.Admit(ctx, store.Identity{Provider: "google", Subject: "t1-owner"}, "t1",
			store.AdmitPolicy{BootstrapOwner: true}, time.Now()); err != nil {
			t.Fatal(err)
		}
		return st
	}
	open := store.AdmitPolicy{OpenWorkspace: "demo", OpenProviders: []string{"google", "facebook"}}

	t.Run("flag off", func(t *testing.T) {
		hooks := store.AuthHooks{H: newStore(t), Policy: store.AdmitPolicy{OpenProviders: open.OpenProviders}}
		r := newRigWith(t, auth.Options{Registrar: hooks, Membership: hooks})
		c := browser(t)
		if u := signIn(t, c, r, "google", "?tenant=demo"); u.Query().Get("auth_error") != auth.ErrCodeNotAllowed {
			t.Fatalf("demo off admitted a visitor: landed on %s", u)
		}
		if code, _ := session(t, c, r); code != http.StatusUnauthorized {
			t.Fatalf("refused sign-in left a session: %d", code)
		}
	})

	t.Run("flag on", func(t *testing.T) {
		st := newStore(t)
		hooks := store.AuthHooks{H: st, Policy: open}
		r := newRigWith(t, auth.Options{Registrar: hooks, Membership: hooks})

		// Another workspace stays invite-only with the demo on.
		c := browser(t)
		if u := signIn(t, c, r, "google", "?tenant=t1"); u.Query().Get("auth_error") != auth.ErrCodeNotAllowed {
			t.Fatalf("open rule leaked to t1: landed on %s", u)
		}

		c = browser(t)
		if u := signIn(t, c, r, "google", "?tenant=demo"); u.Query().Get("auth_error") != "" {
			t.Fatalf("visitor refused: landed on %s", u)
		}
		code, s := session(t, c, r)
		if code != http.StatusOK || s.Tenant != "demo" {
			t.Fatalf("visitor session: %d tenant %q, want the demo workspace", code, s.Tenant)
		}
		if role, err := st.MemberRole(ctx, s.HumanID, "demo"); err != nil || role != rbac.DemoUser {
			t.Fatalf("visitor role %q %v, want demo_user", role, err)
		}
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		hubURL, _ := url.Parse(r.hub)
		for _, ck := range c.Jar.Cookies(hubURL) {
			req.AddCookie(ck)
		}
		if _, err := r.h.SessionForTenant(req, "t1"); err != auth.ErrNotMember {
			t.Fatalf("visitor reached t1: %v", err)
		}
	})
}

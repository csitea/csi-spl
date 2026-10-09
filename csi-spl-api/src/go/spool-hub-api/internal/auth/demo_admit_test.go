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

// specs/077 T008 through the real sign-in: with the demo at its live cap a
// new visitor lands on auth_error=demo_full with no session and no seat.
func TestStoreBackedOpenDemoFull(t *testing.T) {
	ctx := context.Background()
	st := store.NewMemory()
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := st.CreateTenant(ctx, store.Tenant{ID: "demo", RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	full := store.AdmitPolicy{OpenWorkspace: "demo", OpenProviders: []string{"google", "facebook"}, OpenMaxLive: 1}
	if _, err := st.Admit(ctx, store.Identity{Provider: "google", Subject: "first-visitor",
		Email: "first-visitor@example.com"}, "demo", full, time.Now()); err != nil {
		t.Fatal(err)
	}
	hooks := store.AuthHooks{H: st, Policy: full}
	r := newRigWith(t, auth.Options{Registrar: hooks, Membership: hooks})
	c := browser(t)
	if u := signIn(t, c, r, "google", "?tenant=demo"); u.Query().Get("auth_error") != auth.ErrCodeDemoFull {
		t.Fatalf("visitor past the cap: landed on %s, want auth_error=%s", u, auth.ErrCodeDemoFull)
	}
	if code, _ := session(t, c, r); code != http.StatusUnauthorized {
		t.Fatalf("demo_full left a session: %d", code)
	}
}

// specs/077 FR-004, linkedin by the owner (t1 msg fafec44f): a LinkedIn
// visitor naming the demo workspace is seated there as a demo_user through
// the real OIDC sign-in. CONTROL: the same sign-in with linkedin dropped from
// the open providers is refused with no session.
func TestStoreBackedOpenDemoLinkedIn(t *testing.T) {
	ctx := context.Background()
	newStore := func(t *testing.T) *store.Memory {
		st := store.NewMemory()
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := st.CreateTenant(ctx, store.Tenant{ID: "demo", RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
		return st
	}
	for _, c := range []struct {
		name      string
		providers []string
		admitted  bool
	}{
		{"linkedin listed", []string{"google", "facebook", "linkedin"}, true},
		{"CONTROL linkedin dropped", []string{"google", "facebook"}, false},
	} {
		t.Run(c.name, func(t *testing.T) {
			st := newStore(t)
			hooks := store.AuthHooks{H: st, Policy: store.AdmitPolicy{OpenWorkspace: "demo", OpenProviders: c.providers}}
			r := newRigAll(t, auth.Options{Registrar: hooks, Membership: hooks}, nil)
			b := browser(t)
			u := signIn(t, b, r, auth.ProviderLinkedIn, "?tenant=demo")
			code, s := session(t, b, r)
			if !c.admitted {
				if u.Query().Get("auth_error") != auth.ErrCodeNotAllowed || code != http.StatusUnauthorized {
					t.Fatalf("linkedin not listed, still admitted: landed on %s, session %d", u, code)
				}
				return
			}
			if u.Query().Get("auth_error") != "" || code != http.StatusOK || s.Tenant != "demo" || s.Provider != auth.ProviderLinkedIn {
				t.Fatalf("linkedin visitor: landed on %s, session %d %+v, want the demo workspace", u, code, s)
			}
			if role, err := st.MemberRole(ctx, s.HumanID, "demo"); err != nil || role != rbac.DemoUser {
				t.Fatalf("linkedin visitor role %q %v, want demo_user", role, err)
			}
		})
	}
}

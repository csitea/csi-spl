package auth_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/077 T010 through the real sign-in: an account whose demo visits for
// today are used lands on auth_error=demo_visits, and a new account from an
// address that brought its new demo accounts for today on
// auth_error=demo_signups, both with no session. The callback hands the
// store the caller's address: the same seed from ANOTHER address (CONTROL)
// lets the visitor in.
func TestStoreBackedOpenDemoLimits(t *testing.T) {
	ctx := context.Background()
	newStore := func(t *testing.T) *store.Memory {
		st := store.NewMemory()
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := st.CreateTenant(ctx, store.Tenant{ID: "demo", RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
		return st
	}
	open := store.AdmitPolicy{OpenWorkspace: "demo", OpenProviders: []string{"google", "facebook"},
		OpenVisitsPerDay: 1, OpenSignupsPerIP: 1}
	// alice is the rig's fake IdP person; the httptest client is 127.0.0.1.
	visitor := store.Identity{Provider: "google", Subject: alice.Subject, Email: "alice@example.com"}
	other := func(ip string) store.Identity {
		return store.Identity{Provider: "google", Subject: "seed-" + ip, Email: "seed@example.com", ClientIP: ip}
	}
	signInDemo := func(t *testing.T, st *store.Memory) string {
		t.Helper()
		hooks := store.AuthHooks{H: st, Policy: open}
		r := newRigWith(t, auth.Options{Registrar: hooks, Membership: hooks})
		c := browser(t)
		code := signIn(t, c, r, "google", "?tenant=demo").Query().Get("auth_error")
		if s, _ := session(t, c, r); code != "" && s != http.StatusUnauthorized {
			t.Fatalf("auth_error=%s left a session: %d", code, s)
		}
		return code
	}

	t.Run("visits used", func(t *testing.T) {
		st := newStore(t)
		now := time.Now().UTC()
		if _, err := st.Admit(ctx, visitor, "demo", open, now); err != nil {
			t.Fatal(err)
		}
		if _, err := st.SweepDemo(ctx, "demo", store.DefaultDemoMaxStay, now.Add(store.DefaultDemoMaxStay+time.Second)); err != nil {
			t.Fatal(err)
		}
		if code := signInDemo(t, st); code != auth.ErrCodeDemoVisits {
			t.Fatalf("second visit under a limit of 1: auth_error=%q, want %s", code, auth.ErrCodeDemoVisits)
		}
	})
	t.Run("sign-ups from this address used", func(t *testing.T) {
		st := newStore(t)
		if _, err := st.Admit(ctx, other("127.0.0.1"), "demo", open, time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
		if code := signInDemo(t, st); code != auth.ErrCodeDemoSignups {
			t.Fatalf("second account from 127.0.0.1 under a limit of 1: auth_error=%q, want %s", code, auth.ErrCodeDemoSignups)
		}
	})
	t.Run("CONTROL another address", func(t *testing.T) {
		st := newStore(t)
		if _, err := st.Admit(ctx, other("198.51.100.9"), "demo", open, time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
		if code := signInDemo(t, st); code != "" {
			t.Fatalf("first account from 127.0.0.1: auth_error=%q, want admitted", code)
		}
	})
}

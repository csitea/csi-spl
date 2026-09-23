package auth_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"net/http/httptest"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// 010 T012/T013 with the real store hooks: the first callback mints HUM-*,
// a repeat is idempotent, admission decides the tenant, and the CONTROL: a
// valid session of a human who is not a member is refused (ErrNotMember, the
// view door's 401 view_door).
func TestStoreBackedRegistrarAndMembership(t *testing.T) {
	ctx := context.Background()
	st := store.NewMemory()
	for _, id := range []string{"t1", "t2"} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := st.CreateTenant(ctx, store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	// t2 already has an owner, so alice needs an invite there.
	if _, err := st.Admit(ctx, store.Identity{Provider: "google", Subject: "someone-else"}, "t2",
		store.AdmitPolicy{BootstrapOwner: true}, time.Now()); err != nil {
		t.Fatal(err)
	}
	hooks := store.AuthHooks{H: st, Policy: store.AdmitPolicy{BootstrapOwner: true}}
	r := newRigWith(t, auth.Options{Registrar: hooks, Membership: hooks})
	c := browser(t)
	cookieReq := func() *http.Request {
		hubURL, _ := url.Parse(r.hub)
		req := httptest.NewRequest(http.MethodGet, "/", nil)
		for _, ck := range c.Jar.Cookies(hubURL) {
			req.AddCookie(ck)
		}
		return req
	}

	// Not admitted to t2: the callback refuses, no session.
	if u := signIn(t, c, r, "google", "?tenant=t2"); u.Query().Get("auth_error") != auth.ErrCodeNotAllowed {
		t.Fatalf("t2 without invite landed on %s", u)
	}
	if code, _ := session(t, c, r); code != http.StatusUnauthorized {
		t.Fatalf("refused sign-in left a session: %d", code)
	}

	// t1 has zero members: alice bootstraps as owner.
	if u := signIn(t, c, r, "google", "?tenant=t1"); u.Query().Get("auth_error") != "" {
		t.Fatalf("t1 landed on %s", u)
	}
	_, s := session(t, c, r)
	if !strings.HasPrefix(s.HumanID, "HUM-") {
		t.Fatalf("no HUM-* in the session: %+v", s)
	}
	if got, err := r.h.SessionForTenant(cookieReq(), "t1"); err != nil || got.HumanID != s.HumanID {
		t.Fatalf("owner of t1: %v %+v", err, got)
	}
	// CONTROL: same valid session, tenant she is not a member of.
	if _, err := r.h.SessionForTenant(cookieReq(), "t2"); err != auth.ErrNotMember {
		t.Fatalf("non-member of t2 admitted: %v", err)
	}

	// Facebook is a different identity of the SAME person: both providers
	// asserted the same VERIFIED address, so it joins alice's human instead of
	// minting a second, unlinked one (CLE-3451 defect 2).
	c2 := browser(t)
	signIn(t, c2, r, "facebook", "")
	if _, s2 := session(t, c2, r); s2.HumanID != s.HumanID {
		t.Fatalf("facebook identity minted %q, want alice's %q", s2.HumanID, s.HumanID)
	}
	// Same provider again, no tenant: idempotent on (provider, subject).
	c3 := browser(t)
	signIn(t, c3, r, "google", "")
	if _, s3 := session(t, c3, r); s3.HumanID != s.HumanID {
		t.Fatalf("second google callback minted %q, want %q", s3.HumanID, s.HumanID)
	}

	// An invite on the verified email admits alice to t2 as member.
	if err := st.PutInvite(ctx, store.Invite{TenantID: "t2", Email: "alice@example.com", InvitedBy: store.AdmittedOperator,
		ExpiresAt: time.Now().Add(time.Hour)}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if u := signIn(t, c, r, "google", "?tenant=t2"); u.Query().Get("auth_error") != "" {
		t.Fatalf("invited t2 landed on %s", u)
	}
	if _, err := r.h.SessionForTenant(cookieReq(), "t2"); err != nil {
		t.Fatalf("invited member of t2 refused: %v", err)
	}
}

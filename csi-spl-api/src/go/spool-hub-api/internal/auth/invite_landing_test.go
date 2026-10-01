package auth_test

import (
	"context"
	"net/http"
	"net/url"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
)

// landingReg is a Registrar that is also an InviteLander (SPL-1230): land is
// the workspace the verified address is invited to, refuse a tenant whose
// admission fails (a seat cap), asked records the tenant of every Register.
type landingReg struct {
	land, refuse string
	asked        []string
}

func (g *landingReg) InvitedTenant(context.Context, string) (string, error) { return g.land, nil }

func (g *landingReg) Register(_ context.Context, id auth.Identity, tenant string) (string, error) {
	g.asked = append(g.asked, tenant)
	if tenant != "" && tenant == g.refuse {
		return "", auth.ErrNotAllowed
	}
	return "HUM-" + id.Subject + "@" + tenant, nil
}

// SPL-1230: a sign-in that names NO workspace lands in the one the verified
// address is invited to, instead of nowhere (the invite would stay pending).
func TestOAuthSignInLandsInInvitedTenant(t *testing.T) {
	reg := &landingReg{land: "t1"}
	r := newRig(t, reg)
	c := browser(t)
	signIn(t, c, r, auth.ProviderGoogle, "?redirect=/")
	if code, s := session(t, c, r); code != http.StatusOK || s.Tenant != "t1" || s.HumanID != "HUM-sub-123@t1" {
		t.Fatalf("session %d %+v, want tenant t1", code, s)
	}
	if len(reg.asked) != 1 || reg.asked[0] != "t1" {
		t.Fatalf("registrar asked %v, want [t1]", reg.asked)
	}
}

// CONTROL: a sign-in that NAMES a workspace keeps it; the lander is not asked
// to override an explicit choice.
func TestOAuthSignInKeepsNamedTenant(t *testing.T) {
	reg := &landingReg{land: "t1"}
	r := newRig(t, reg)
	c := browser(t)
	signIn(t, c, r, auth.ProviderGoogle, "?redirect=/&tenant=t9")
	if _, s := session(t, c, r); s.Tenant != "t9" {
		t.Fatalf("tenant %q, want the named t9", s.Tenant)
	}
	if len(reg.asked) != 1 || reg.asked[0] != "t9" {
		t.Fatalf("registrar asked %v, want [t9]", reg.asked)
	}
}

// A refused invite admission (seat cap, revoked meanwhile) must not lose the
// sign-in: it falls back to the tenant-less sign-in it was before SPL-1230.
func TestOAuthSignInInviteRefusedFallsBack(t *testing.T) {
	reg := &landingReg{land: "t1", refuse: "t1"}
	r := newRig(t, reg)
	c := browser(t)
	signIn(t, c, r, auth.ProviderGoogle, "?redirect=/")
	if code, s := session(t, c, r); code != http.StatusOK || s.Tenant != "" || s.HumanID != "HUM-sub-123@" {
		t.Fatalf("session %d %+v, want signed in, no tenant", code, s)
	}
	if strings.Join(reg.asked, ",") != "t1," {
		t.Fatalf("registrar asked %v, want [t1 \"\"]", reg.asked)
	}
}

// SPL-1230, native: an email + password login with no workspace lands in the
// invited one too.
func TestNativeLoginLandsInInvitedTenant(t *testing.T) {
	r := newNRig(t, nil, nil, true)
	r.reg.land = "t1"
	c := browser(t)
	if got := r.post(t, c, "register", map[string]string{"email": "invitee@example.com", "password": pwA}); got.code != http.StatusAccepted {
		t.Fatalf("register: %d %s", got.code, got.raw)
	}
	if got := r.post(t, c, "email/verify", map[string]string{"token": r.lastToken(t, "email_verification"), "password": pwA}); got.code != http.StatusNoContent {
		t.Fatalf("verify: %d %s", got.code, got.raw)
	}
	got := r.post(t, c, "login", map[string]string{"email": "invitee@example.com", "password": pwA})
	if got.code != http.StatusOK || got.body["t"] != "t1" {
		t.Fatalf("login: %d %s, want t=t1", got.code, got.raw)
	}
	if len(r.reg.tenants) != 1 || r.reg.tenants[0] != "t1" {
		t.Fatalf("registrar tenants %v, want [t1]", r.reg.tenants)
	}
}

// SPL-1231: /start forwards a plain-address login_hint to Google and
// Microsoft (pre-selects the invited account), lower-cased; never to Facebook,
// and never a value that is not an address.
func TestStartForwardsLoginHint(t *testing.T) {
	r := newRig(t, &landingReg{})
	loc := func(provider, q string) url.Values {
		t.Helper()
		resp, err := noFollow(browser(t)).Get(r.hub + "/api/v1/auth/" + provider + "/start" + q)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		u, err := url.Parse(resp.Header.Get("Location"))
		if err != nil {
			t.Fatal(err)
		}
		return u.Query()
	}
	if got := loc(auth.ProviderGoogle, "?login_hint="+url.QueryEscape("Invitee@Example.com")).Get("login_hint"); got != "invitee@example.com" {
		t.Fatalf("google login_hint %q", got)
	}
	if q := loc(auth.ProviderGoogle, "?login_hint="+url.QueryEscape("not an address")); q.Has("login_hint") {
		t.Fatalf("a non-address hint was forwarded: %v", q)
	}
	if q := loc(auth.ProviderFacebook, "?login_hint="+url.QueryEscape("invitee@example.com")); q.Has("login_hint") {
		t.Fatalf("facebook got a login_hint: %v", q)
	}
	if q := loc(auth.ProviderGoogle, ""); q.Has("login_hint") || q.Get("state") == "" {
		t.Fatalf("no hint asked: %v", q)
	}
}

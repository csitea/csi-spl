package auth_test

import (
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
)

// spec 018. Every negative case runs beside its positive control on the same
// rig: the honest token signs in, the tampered one does not.

const workTID = "72f988bf-86f1-41af-91ab-2d7cd011db47"

var (
	msPersonal = fakeidp.Person{Subject: "ms-personal", Email: "Pat@Example.com", Name: "FirstName LastName"}
	msWork     = fakeidp.Person{Subject: "ms-work", Email: "Wes@Example.org", Name: "FirstName LastName",
		MicrosoftTenantID: workTID, EmailDomainVerified: true}
)

func msSignIn(t *testing.T, r *rig) (string, auth.Session) {
	t.Helper()
	c := browser(t)
	landed := signIn(t, c, r, auth.ProviderMicrosoft, "")
	if landed.Path == "/login" {
		return landed.Query().Get("auth_error"), auth.Session{}
	}
	code, s := session(t, c, r)
	if code != http.StatusOK {
		t.Fatalf("landed on %s but session = %d", landed, code)
	}
	return "", s
}

func msRig(t *testing.T, extra map[string]string, p fakeidp.Person) *rig {
	t.Helper()
	r := newRigAll(t, auth.Options{}, extra)
	r.fake.Set(p, false)
	return r
}

// SC-001: a personal account and a work account whose tenant verified the
// email domain both sign in; the subject is <tid>/<oid> (FR-004).
func TestMicrosoftSignIn(t *testing.T) {
	for _, p := range []fakeidp.Person{msPersonal, msWork} {
		r := msRig(t, nil, p)
		e, s := msSignIn(t, r)
		want := fakeidp.MicrosoftTenantOf(p) + "/" + fakeidp.MicrosoftOID(p.Subject)
		if e != "" || s.Subject != want || s.Provider != auth.ProviderMicrosoft || s.Email == "" || s.Email != toLower(p.Email) {
			t.Fatalf("%s: auth_error=%q session %+v, want subject %s", p.Subject, e, s, want)
		}
	}
}

func toLower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if 'A' <= c && c <= 'Z' {
			b[i] = c + 32
		}
	}
	return string(b)
}

// FR-005: a work account without xms_edov is refused (nOAuth); the owner's
// override admits it outside prd.
func TestMicrosoftWorkEmailNeedsVerifiedDomain(t *testing.T) {
	unverified := msWork
	unverified.EmailDomainVerified = false
	if e, _ := msSignIn(t, msRig(t, nil, unverified)); e != auth.ErrCodeUnverified {
		t.Fatalf("work account without xms_edov: auth_error=%q", e)
	}
	if e, _ := msSignIn(t, msRig(t, nil, msWork)); e != "" {
		t.Fatalf("CONTROL work account with xms_edov: auth_error=%q", e)
	}
	trust := map[string]string{"SPOOL_HUB_AUTH_MICROSOFT_TRUST_EMAIL": "true"}
	if e, _ := msSignIn(t, msRig(t, trust, unverified)); e != "" {
		t.Fatalf("TRUST_EMAIL in lde: auth_error=%q", e)
	}
	noMail := msPersonal
	noMail.Email = ""
	if e, _ := msSignIn(t, msRig(t, nil, noMail)); e != auth.ErrCodeUnverified {
		t.Fatalf("no email claim: auth_error=%q", e)
	}
}

// FR-001: the account's tid must fit the configured authority.
func TestMicrosoftTenantMode(t *testing.T) {
	cases := []struct {
		tenant string
		p      fakeidp.Person
		ok     bool
	}{
		{"common", msPersonal, true}, {"common", msWork, true},
		{"consumers", msPersonal, true}, {"consumers", msWork, false},
		{"organizations", msWork, true}, {"organizations", msPersonal, false},
		{workTID, msWork, true}, {workTID, msPersonal, false},
		{"0b1e6f2c-1111-2222-3333-444455556666", msWork, false},
	}
	for _, c := range cases {
		r := msRig(t, map[string]string{"SPOOL_HUB_AUTH_MICROSOFT_TENANT": c.tenant}, c.p)
		e, _ := msSignIn(t, r)
		if c.ok && e != "" || !c.ok && e != auth.ErrCodeExchange {
			t.Errorf("tenant %s, account tid %s: auth_error=%q, want ok=%v", c.tenant, fakeidp.MicrosoftTenantOf(c.p), e, c.ok)
		}
	}
}

// FR-003 / SC-002: every id_token check refuses its forgery.
func TestMicrosoftIDTokenForgeriesRefused(t *testing.T) {
	now := time.Now()
	cases := map[string]fakeidp.MicrosoftTamper{
		"aud":            {Claims: func(c map[string]any) { c["aud"] = "another-client" }},
		"aud array":      {Claims: func(c map[string]any) { c["aud"] = []string{"another-client"} }},
		"iss other tid":  {Claims: func(c map[string]any) { c["iss"] = "http://evil.example/" + workTID + "/v2.0" }},
		"iss vs tid":     {Claims: func(c map[string]any) { c["tid"] = workTID; c["xms_edov"] = true }},
		"tid not a guid": {Claims: func(c map[string]any) { c["tid"] = "common" }},
		"oid missing":    {Claims: func(c map[string]any) { delete(c, "oid") }},
		"nonce":          {Claims: func(c map[string]any) { c["nonce"] = "replayed" }},
		"nonce missing":  {Claims: func(c map[string]any) { delete(c, "nonce") }},
		"expired":        {Claims: func(c map[string]any) { c["exp"] = now.Add(-time.Hour).Unix() }},
		"no exp":         {Claims: func(c map[string]any) { delete(c, "exp") }},
		"nbf future":     {Claims: func(c map[string]any) { c["nbf"] = now.Add(time.Hour).Unix() }},
		"iat future":     {Claims: func(c map[string]any) { c["iat"] = now.Add(time.Hour).Unix() }},
		"alg none":       {Header: func(h map[string]any) { h["alg"] = "none" }},
		"alg HS256":      {Header: func(h map[string]any) { h["alg"] = "HS256" }},
		"no kid":         {Header: func(h map[string]any) { delete(h, "kid") }},
		"unknown kid":    {Header: func(h map[string]any) { h["kid"] = "rolled" }},
		"bad signature":  {BadSignature: true},
	}
	r := msRig(t, nil, msPersonal)
	for name, tamper := range cases {
		r.fake.SetMicrosoftTamper(tamper)
		if e, _ := msSignIn(t, r); e != auth.ErrCodeExchange {
			t.Errorf("%s: auth_error=%q, want %s", name, e, auth.ErrCodeExchange)
		}
		r.fake.SetMicrosoftTamper(fakeidp.MicrosoftTamper{})
		if e, _ := msSignIn(t, r); e != "" {
			t.Fatalf("CONTROL after %s: honest token refused: %q", name, e)
		}
	}
}

// FR-002: the authorize request carries an S256 challenge and never the
// verifier; a token call whose verifier does not hash to the challenge fails.
func TestMicrosoftPKCE(t *testing.T) {
	r := msRig(t, nil, msPersonal)
	resp, err := noFollow(browser(t)).Get(r.hub + "/api/v1/auth/microsoft/start")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	loc, _ := url.Parse(resp.Header.Get("Location"))
	q := loc.Query()
	if q.Get("code_challenge_method") != "S256" || len(q.Get("code_challenge")) != 43 || q.Has("code_verifier") ||
		q.Get("nonce") == "" || q.Get("response_mode") != "query" {
		t.Fatalf("authorize URL %s", loc)
	}
	if e, _ := msSignIn(t, r); e != "" {
		t.Fatalf("CONTROL: %q", e)
	}
	// start + authorize with the real key, then redeem the code with another
	// verifier: an intercepted code is useless without the flow's verifier
	c := browser(t)
	resp, err = noFollow(c).Get(r.hub + "/api/v1/auth/microsoft/start")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	resp, err = noFollow(c).Get(resp.Header.Get("Location"))
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	cb := resp.Header.Get("Location")
	auth.BreakMicrosoftPKCE(r.h)
	resp, err = c.Get(cb)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if e := authError(resp.Request.URL); e != auth.ErrCodeExchange {
		t.Fatalf("wrong verifier: auth_error=%q", e)
	}
}

// FR-003: the JWKS is fetched once and cached; an unknown kid refetches at
// most once per minute.
func TestMicrosoftJWKSCache(t *testing.T) {
	r := msRig(t, nil, msPersonal)
	for i := 0; i < 3; i++ {
		if e, _ := msSignIn(t, r); e != "" {
			t.Fatal(e)
		}
	}
	if n := r.fake.MicrosoftJWKSFetches(); n != 1 {
		t.Fatalf("JWKS fetched %d times for 3 sign-ins, want 1", n)
	}
	// an unknown kid within a minute of the last fetch does not refetch
	r.fake.SetMicrosoftTamper(fakeidp.MicrosoftTamper{Header: func(h map[string]any) { h["kid"] = "rolled" }})
	msSignIn(t, r)
	if n := r.fake.MicrosoftJWKSFetches(); n != 1 {
		t.Fatalf("unknown kid inside the refetch floor fetched: %d", n)
	}
	// two minutes on: one refetch for a burst of unknown kids, not one each
	later := time.Now().Add(2 * time.Minute)
	auth.SetMicrosoftJWKSClock(r.h, func() time.Time { return later })
	for i := 0; i < 3; i++ {
		msSignIn(t, r)
	}
	if n := r.fake.MicrosoftJWKSFetches(); n != 2 {
		t.Fatalf("JWKS fetched %d times after 3 unknown kids, want 2 (one refetch)", n)
	}
	// the known key still works from the cache
	r.fake.SetMicrosoftTamper(fakeidp.MicrosoftTamper{})
	if e, _ := msSignIn(t, r); e != "" || r.fake.MicrosoftJWKSFetches() != 2 {
		t.Fatalf("CONTROL: %q, fetches %d", e, r.fake.MicrosoftJWKSFetches())
	}
}

package hub_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-959 (owner option B, 2026-09-26): the WUI of tenant <t> is served on
// https://<t>.<fqdn> and the apex https://<fqdn> is the apex tenant. The hub
// serves a browser request as the tenant its Origin names, per request, and
// only to a member; credentialed CORS admits exactly those hosts of THIS env.
func TestOriginTenantOf(t *testing.T) {
	ot := hub.NewOriginTenant("{tenant}.spool.test", "t1")
	for _, c := range []struct{ origin, want string }{
		{"https://acme.spool.test", "acme"},
		{"https://ACME.spool.test", "acme"},
		{"https://spool.test", "t1"},      // the apex is the apex tenant
		{"https://dev.spool.test", ""},    // the other env's WUI: a reserved label
		{"https://api.spool.test", ""},    // the hub itself: reserved
		{"https://x.acme.spool.test", ""}, // a dot is no tenant id
		{"https://acme.dev.spool.test", ""},
		{"http://acme.spool.test", ""}, // https only
		{"https://acme.spool.test:8443", ""},
		{"https://acme.spool.test/path", ""},
		{"https://acme.spool.test.evil.test", ""},
		{"https://evilspool.test", ""},
		{"null", ""},
		{"", ""},
	} {
		if got := ot.Of(c.origin); got != c.want {
			t.Errorf("Of(%q) = %q, want %q", c.origin, got, c.want)
		}
	}
	// the apex is an exact CORS entry, never the pattern half
	if ot.TenantHost("https://spool.test") || !ot.TenantHost("https://acme.spool.test") || ot.TenantHost("https://dev.spool.test") {
		t.Fatal("TenantHost")
	}
	dev := hub.NewOriginTenant("{tenant}.dev.spool.test", "")
	if dev.Of("https://acme.spool.test") != "" || dev.Of("https://acme.dev.spool.test") != "acme" || dev.Of("https://dev.spool.test") != "" {
		t.Fatal("dev pattern must not match prd hosts")
	}
	var off *hub.OriginTenant // tenant hosts off
	if off.Of("https://acme.spool.test") != "" || off.TenantHost("https://acme.spool.test") {
		t.Fatal("nil resolver must answer nothing")
	}
	if hub.NewOriginTenant("hub.test", "") != nil {
		t.Fatal("a pattern without {tenant}. must be refused")
	}
}

// originReq is a browser GET on the api host from a page on origin: status,
// body and the CORS origin the hub answered.
func (r *doorRig) originReq(t *testing.T, origin, path string) (int, string, string) {
	t.Helper()
	rq, _ := http.NewRequest(http.MethodGet, "http://"+apiLabel+domain+path, nil)
	if origin != "" {
		rq.Header.Set("Origin", origin)
	}
	resp, err := r.browser.Do(rq)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b), resp.Header.Get("Access-Control-Allow-Origin")
}

func TestTenantHostsServeTheOriginTenant(t *testing.T) {
	b4 := make([]byte, 4)
	rand.Read(b4) //nolint:errcheck
	apex := "t" + hex.EncodeToString(b4)
	pattern := "{tenant}" + domain                             // the rig's SPOOL_HUB_TENANT_HOST_PATTERN
	apexOrigin := "https://" + strings.TrimPrefix(domain, ".") // an exact CORS entry, as in cnf
	r := newDoorRig(t, func(o *hub.Options) {
		o.OriginTenant = hub.NewOriginTenant(pattern, apex)
		o.ViewCORSOrigins = append(o.ViewCORSOrigins, apexOrigin)
	})
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := r.e.st.CreateTenant(context.Background(), store.Tenant{ID: apex, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	a, _ := r.e.tenant()
	b, _ := r.e.tenant()
	c, _ := r.e.tenant()
	sub := "hosts-" + a
	r.fake.Set(fakeidp.Person{Subject: sub, Email: sub + "@example.com", EmailVerified: true, Name: "FirstName LastName"}, false)
	hs := r.e.st.(store.Humans)
	for _, tn := range []string{a, b, apex} {
		if _, err := hs.Admit(context.Background(), store.Identity{Provider: "google", Subject: sub, Email: sub + "@example.com"},
			tn, store.AdmitPolicy{BootstrapOwner: true}, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	aOther := ownedByInvite(t, r.e, a, "other-in-a-"+a)
	bOther := ownedByInvite(t, r.e, b, "other-in-b-"+b)
	apexOther := ownedByInvite(t, r.e, apex, "other-in-apex-"+apex)
	cOwner := ownedBy(t, r.e, c, "owner-of-c-"+c)
	host := func(tn string) string { return "https://" + tn + domain }

	// CONTROL: no session, a tenant host still gets CORS but no data.
	if code, body, _ := r.originReq(t, host(a), "/v1/view/roster"); code != http.StatusUnauthorized {
		t.Fatalf("anonymous on A's host: %d %s", code, body)
	}
	// One sign-in, bound to B.
	if landed := r.signIn(t, b); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in: %s", landed)
	}
	// Each page reads its OWN tenant with that one session, whatever `t` is.
	for _, c := range []struct {
		origin, tenant, has, hasNot string
	}{
		{host(a), a, aOther, bOther},
		{host(b), b, bOther, aOther},
		{apexOrigin, apex, apexOther, aOther},
		{host(a), a, aOther, apexOther}, // back again: nothing was switched
	} {
		code, body, acao := r.originReq(t, c.origin, "/v1/view/roster")
		if code != http.StatusOK || !strings.Contains(body, c.has) || strings.Contains(body, c.hasNot) {
			t.Fatalf("page %s: %d %s", c.origin, code, body)
		}
		if acao != c.origin {
			t.Fatalf("page %s: ACAO %q", c.origin, acao)
		}
	}
	// The session read names the page's tenant.
	if code, body, _ := r.originReq(t, host(a), "/api/v1/auth/session"); code != http.StatusOK || !strings.Contains(body, `"active_tenant":"`+a+`"`) {
		t.Fatalf("session on A's page: %d %s", code, body)
	}
	// Not a member of C: 403 not_member, never C's data.
	if code, body, acao := r.originReq(t, host(c), "/v1/view/roster"); code != http.StatusForbidden || errToken([]byte(body)) != "not_member" ||
		strings.Contains(body, cOwner) || acao != host(c) {
		t.Fatalf("page of a non-member tenant: %d %s (acao %q)", code, body, acao)
	}
	// An unknown tenant host reads the same as a non-member one.
	if code, body, _ := r.originReq(t, host("nosuch"+a), "/v1/view/roster"); code != http.StatusForbidden || errToken([]byte(body)) != "not_member" {
		t.Fatalf("page of an unknown tenant: %d %s", code, body)
	}
	// CONTROLS: the other env's WUI, a nested host, plain http: no CORS, and
	// the session's own tenant (B) as before, never the host they name.
	for _, o := range []string{"https://dev" + domain, "https://x." + a + domain, "http://" + a + domain, "https://" + a + domain + ".evil.test"} {
		code, body, acao := r.originReq(t, o, "/v1/view/roster")
		if acao != "" {
			t.Fatalf("origin %s got ACAO %q", o, acao)
		}
		if code != http.StatusOK || !strings.Contains(body, bOther) {
			t.Fatalf("origin %s: %d %s", o, code, body)
		}
	}
	// A box/CLI (no Origin) keeps the session's tenant.
	if code, body, _ := r.originReq(t, "", "/v1/view/roster"); code != http.StatusOK || !strings.Contains(body, bOther) {
		t.Fatalf("no origin: %d %s", code, body)
	}
}

// CONTROL: with tenant hosts off (the default) a tenant host is a foreign
// origin: no CORS, and the page's host selects nothing.
func TestTenantHostsOffByDefault(t *testing.T) {
	r := newDoorRig(t)
	a, _ := r.e.tenant()
	if landed := r.signIn(t, a); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in: %s", landed)
	}
	b, _ := r.e.tenant()
	code, body, acao := r.originReq(t, "https://"+b+domain, "/v1/view/roster")
	if acao != "" || code != http.StatusOK {
		t.Fatalf("tenant hosts off: %d %s acao %q", code, body, acao)
	}
}

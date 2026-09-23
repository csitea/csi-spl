package hub_test

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// specs/026: the tenant comes from the identity. "api" is a reserved label,
// so api.hub.test is the single api host: it names no tenant.
const apiLabel = "api"

// sessionView is GET /api/v1/auth/session with the 026 fields.
type sessionView struct {
	HumanID      string  `json:"hum"`
	Tenant       string  `json:"t"`
	ActiveTenant *string `json:"active_tenant"`
	Tenants      []struct {
		TenantID string `json:"tenant_id"`
		Role     string `json:"role"`
	} `json:"tenants"`
}

func (r *doorRig) sessionView(t *testing.T) sessionView {
	t.Helper()
	resp, err := r.browser.Get("http://" + loginHost + "/api/v1/auth/session")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var s sessionView
	if err := json.NewDecoder(resp.Body).Decode(&s); err != nil {
		t.Fatal(err)
	}
	return s
}

// req is a browser request to host (a tenant label or apiLabel) with extra headers.
func (r *doorRig) req(t *testing.T, method, host, path string, h http.Header, body io.Reader) (int, string) {
	t.Helper()
	rq, _ := http.NewRequest(method, "http://"+host+domain+path, body)
	rq.Header.Set("Origin", wuiOrigin)
	for k, v := range h {
		rq.Header[k] = v
	}
	resp, err := r.browser.Do(rq)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

// ownedBy seats another human as the owner of tenant (bootstrap), so the
// rig's person (alice) is not admitted there by her own sign-in.
func ownedBy(t *testing.T, e *env, tenant, subject string) string {
	t.Helper()
	hum, err := e.st.(store.Humans).Admit(context.Background(),
		store.Identity{Provider: "google", Subject: subject}, tenant, store.AdmitPolicy{BootstrapOwner: true}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return hum
}

// A member of A with a session reads A on the api host, and can never read or
// write B: not with B's Host (403 tenant_mismatch), not with ?tenant=B or
// X-Spool-Tenant: B (ignored for humans), on every browser door.
func TestCrossTenantIdentityHumanNeverReachesOtherTenant(t *testing.T) {
	r := newDoorRig(t)
	a, _ := r.e.tenant()
	b, _ := r.e.tenant()
	bOwner := ownedBy(t, r.e, b, "owner-of-b")
	if landed := r.signIn(t, a); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in to A: %s", landed)
	}
	sv := r.sessionView(t)
	if sv.ActiveTenant == nil || *sv.ActiveTenant != a || len(sv.Tenants) == 0 {
		t.Fatalf("session: %+v, want active %s and tenants [%s]", sv, a, a)
	}

	// Positive first: the api host serves A's roster (alice in it, B's owner not).
	code, body := r.req(t, http.MethodGet, apiLabel, "/v1/view/roster", nil, nil)
	if code != http.StatusOK || !strings.Contains(body, sv.HumanID) || strings.Contains(body, bOwner) {
		t.Fatalf("api host roster: %d %s", code, body)
	}
	// The legacy host of A still works (Host equals the identity's tenant).
	if code, body := r.req(t, http.MethodGet, a, "/v1/view/roster", nil, nil); code != http.StatusOK {
		t.Fatalf("legacy host A: %d %s", code, body)
	}

	// CONTROL: B named by a param or a header is ignored: still A's roster.
	hdrB := http.Header{hub.TenantHeader: {b}}
	for _, p := range []string{"/v1/view/roster?tenant=" + b, "/v1/view/roster"} {
		code, body := r.req(t, http.MethodGet, apiLabel, p, hdrB, nil)
		if code != http.StatusOK || strings.Contains(body, bOwner) || !strings.Contains(body, sv.HumanID) {
			t.Fatalf("api host %s naming B: %d %s", p, code, body)
		}
	}

	// CONTROL: B's Host on every browser door is 403 tenant_mismatch.
	for _, c := range []struct{ method, path, body string }{
		{http.MethodGet, "/v1/view/roster", ""},
		{http.MethodGet, "/v1/view/topics", ""},
		{http.MethodGet, "/v1/files/" + strings.Repeat("0", 64), ""},
		{http.MethodPost, "/v1/channels", `{"channel":"x-from-a"}`},
	} {
		code, body := r.req(t, c.method, b, c.path, http.Header{"Content-Type": {"application/json"}}, strings.NewReader(c.body))
		if code != http.StatusForbidden || errToken([]byte(body)) != "tenant_mismatch" {
			t.Fatalf("B host %s %s: %d %s", c.method, c.path, code, body)
		}
	}
	if _, resp, err := websocket.Dial(context.Background(), "ws://"+b+domain+"/v1/wui/ws",
		&websocket.DialOptions{HTTPClient: r.browser}); err == nil || resp == nil || resp.StatusCode != http.StatusForbidden {
		t.Fatalf("B host WUI ws: %v %v", err, resp)
	}
	// Nothing was written to B.
	if err := r.e.st.CreateChannel(context.Background(), store.Channel{TenantID: b, ChannelID: "x-from-a",
		Name: "x", CreatedBy: "test", CreatedAt: time.Now()}); err != nil {
		t.Fatalf("a channel reached B (the id is taken): %v", err)
	}
	// The WUI socket on the api host is A's.
	c, _, err := websocket.Dial(context.Background(), "ws://"+apiLabel+domain+"/v1/wui/ws",
		&websocket.DialOptions{HTTPClient: r.browser})
	if err != nil {
		t.Fatalf("api host WUI ws: %v", err)
	}
	c.CloseNow() //nolint:errcheck
}

// A human in two tenants with no active one is 409 tenant_required on the api
// host; with one bound at sign-in only that one is served. A removed
// membership falls back to the remaining one.
func TestCrossTenantIdentityActiveTenantSelection(t *testing.T) {
	r := newDoorRig(t)
	a, _ := r.e.tenant()
	b, _ := r.e.tenant()
	hs := r.e.st.(store.Humans)
	alice := store.Identity{Provider: "google", Subject: "alice-sub", Email: "alice@example.com"}
	for _, tn := range []string{a, b} {
		if _, err := hs.Admit(context.Background(), alice, tn, store.AdmitPolicy{BootstrapOwner: true}, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	aOther := ownedByInvite(t, r.e, a, "other-in-a")

	// Signed in with no tenant: two memberships, none bound.
	if landed := r.signIn(t, ""); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in: %s", landed)
	}
	sv := r.sessionView(t)
	// >= 2: on the Postgres run other tests seat the same fake person too.
	has := map[string]bool{}
	for _, m := range sv.Tenants {
		has[m.TenantID] = true
	}
	if sv.Tenant != "" || sv.ActiveTenant != nil || !has[a] || !has[b] {
		t.Fatalf("unbound session: %+v", sv)
	}
	if code, body := r.req(t, http.MethodGet, apiLabel, "/v1/view/roster", nil, nil); code != http.StatusConflict || errToken([]byte(body)) != "tenant_required" {
		t.Fatalf("ambiguous api host: %d %s", code, body)
	}
	// A legacy host picks among her memberships (it equals one of them).
	if code, body := r.req(t, http.MethodGet, a, "/v1/view/roster", nil, nil); code != http.StatusOK || !strings.Contains(body, aOther) {
		t.Fatalf("legacy host A while unbound: %d %s", code, body)
	}

	// Bound to B at sign-in: the api host is B's, A's host is a mismatch.
	if landed := r.signIn(t, b); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in to B: %s", landed)
	}
	sv = r.sessionView(t)
	if sv.ActiveTenant == nil || *sv.ActiveTenant != b {
		t.Fatalf("bound session: %+v", sv)
	}
	if code, body := r.req(t, http.MethodGet, apiLabel, "/v1/view/roster", nil, nil); code != http.StatusOK || strings.Contains(body, aOther) {
		t.Fatalf("api host bound to B: %d %s", code, body)
	}
	if code, body := r.req(t, http.MethodGet, a, "/v1/view/roster", nil, nil); code != http.StatusForbidden || errToken([]byte(body)) != "tenant_mismatch" {
		t.Fatalf("A host while bound to B: %d %s", code, body)
	}
}

// ownedByInvite admits another human to tenant through an invite, so the
// tenant's roster has a recognisable second member.
func ownedByInvite(t *testing.T, e *env, tenant, subject string) string {
	t.Helper()
	hs := e.st.(store.Humans)
	email := subject + "@example.com"
	if err := hs.PutInvite(context.Background(), store.Invite{TenantID: tenant, Email: email, Role: "member",
		InvitedBy: "operator", ExpiresAt: time.Now().Add(time.Hour)}, time.Now()); err != nil {
		t.Fatal(err)
	}
	hum, err := hs.Admit(context.Background(), store.Identity{Provider: "google", Subject: subject, Email: email},
		tenant, store.AdmitPolicy{}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	return hum
}

// A box pinned to A that names B is refused at hello; its upload token is
// A's only (a B Host or a B header is 403); the api host needs a named tenant.
func TestCrossTenantIdentityBoxPinnedToOneTenant(t *testing.T) {
	e := newEnv(t)
	a, _ := e.tenant()
	b, _ := e.tenant()
	bx := e.box(a, "box-a", "AGENT-A")
	e.pin(a, bx)

	hello := func(host string, h http.Header) (wire.Frame, error) {
		t.Helper()
		c, code := e.dialWS(host, "/v1/ws", h)
		if c == nil {
			t.Fatalf("dial %s %v: %d", host, h, code)
		}
		ctx := context.Background()
		var ch wire.Frame
		if err := wsjson.Read(ctx, c, &ch); err != nil {
			t.Fatal(err)
		}
		if err := wsjson.Write(ctx, c, helloFrame(bx, ch.Nonce, time.Now().UTC().Format(time.RFC3339), wire.RoleCLI)); err != nil {
			t.Fatal(err)
		}
		var f wire.Frame
		return f, wsjson.Read(ctx, c, &f)
	}

	// Positive: the api host with the box's own tenant named.
	wel, err := hello(apiLabel, http.Header{hub.TenantHeader: {a}})
	if err != nil || wel.Type != wire.TWelcome || wel.UploadToken == "" {
		t.Fatalf("api host hello as A: %v %+v", err, wel)
	}
	// CONTROL: the same box naming B is refused (no pin of box-a in B).
	if f, err := hello(apiLabel, http.Header{hub.TenantHeader: {b}}); err == nil {
		t.Fatalf("hello naming B was accepted: %+v", f)
	} else if websocket.CloseStatus(err) != wire.CloseUnauthorized {
		t.Fatalf("hello naming B: %v", err)
	}
	// CONTROL: header A on B's legacy host is 403 before any upgrade.
	if _, code := e.dialWS(b, "/v1/ws", http.Header{hub.TenantHeader: {a}}); code != http.StatusForbidden {
		t.Fatalf("A named on B's host: %d", code)
	}
	// CONTROL: the api host with no tenant named is 400.
	if _, code := e.dialWS(apiLabel, "/v1/ws", nil); code != http.StatusBadRequest {
		t.Fatalf("api host, no tenant named: %d", code)
	}

	get := func(host, tok string, h http.Header) int {
		t.Helper()
		rq, _ := http.NewRequest(http.MethodGet, "http://"+host+domain+"/v1/pins", nil)
		rq.Header.Set("Authorization", "Bearer "+tok)
		for k, v := range h {
			rq.Header[k] = v
		}
		resp, err := e.client.Do(rq)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		return resp.StatusCode
	}
	// Positive: the token reads its own tenant on the api host and on A's host.
	if c := get(apiLabel, wel.UploadToken, nil); c != http.StatusOK {
		t.Fatalf("token on api host: %d", c)
	}
	if c := get(a, wel.UploadToken, nil); c != http.StatusOK {
		t.Fatalf("token on A host: %d", c)
	}
	// CONTROL: the same token pointed at B.
	if c := get(b, wel.UploadToken, nil); c != http.StatusForbidden {
		t.Fatalf("A token on B host: %d", c)
	}
	if c := get(apiLabel, wel.UploadToken, http.Header{hub.TenantHeader: {b}}); c != http.StatusForbidden {
		t.Fatalf("A token naming B: %d", c)
	}
}

// The box client on the api host (specs/026 §4): SPOOL_TENANT is sent as
// X-Spool-Tenant and the pin proves it; naming another tenant fails the hello.
func TestCrossTenantIdentityBoxClientOnAPIHost(t *testing.T) {
	e := newEnv(t)
	a, _ := e.tenant()
	b, _ := e.tenant()
	bx := e.box(a, "box-a", "AGENT-A")
	e.pin(a, bx)
	bx.cfg.HubURL = "http://" + apiLabel + domain
	ctx := context.Background()

	bx.cfg.Tenant = a
	s, err := bx.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatalf("api host as A: %v", err)
	}
	if err := s.SyncPins(ctx); err != nil { // REST carries the header too
		t.Fatalf("pins via api host: %v", err)
	}
	s.Close()

	bx.cfg.Tenant = b
	if s, err := bx.c.Dial(ctx, wire.RoleCLI); err == nil {
		s.Close()
		t.Fatal("box pinned to A dialled in as B")
	}
	bx.cfg.Tenant = ""
	if s, err := bx.c.Dial(ctx, wire.RoleCLI); err == nil {
		s.Close()
		t.Fatal("api host with no tenant named was accepted")
	}
}

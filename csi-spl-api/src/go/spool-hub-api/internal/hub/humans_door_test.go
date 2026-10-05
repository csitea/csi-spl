package hub_test

import (
	"context"
	"encoding/json"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// doorRig is a hub in the session door with store-backed Registrar and
// Membership (010 T011-T013), a fake IdP and a browser whose cookie jar spans
// every tenant host (cookie Domain = the hub domain, as prd's apex).
type doorRig struct {
	e       *env
	fake    *fakeidp.IdP
	browser *http.Client
}

const (
	loginHost = "login" + domain // auth routes answer on any Host
	idpHost   = "idp.test"
	wuiHost   = "wui.test"
)

func newDoorRig(t *testing.T, mut ...func(*hub.Options)) *doorRig {
	t.Helper()
	g := fakeidp.Client{ID: "gid", Secret: "gsecret", RedirectURI: "http://" + loginHost + "/api/v1/auth/google/callback"}
	f := fakeidp.Client{ID: "fid", Secret: "fsecret", RedirectURI: "http://" + loginHost + "/api/v1/auth/facebook/callback"}
	fake := fakeidp.New(g, f, fakeidp.Person{Subject: "alice-sub", Email: "alice@example.com", EmailVerified: true, Name: "FirstName LastName"})
	idp := httptest.NewServer(fake.Handler())
	t.Cleanup(idp.Close)
	wui := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }))
	t.Cleanup(wui.Close)

	var hubAddr string
	route := func(host string) string {
		switch strings.Split(host, ":")[0] {
		case idpHost:
			return idp.Listener.Addr().String()
		case wuiHost:
			return wui.Listener.Addr().String()
		}
		return hubAddr
	}
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.DialContext = func(ctx context.Context, network, addr string) (net.Conn, error) {
		return (&net.Dialer{}).DialContext(ctx, network, route(addr))
	}
	cfg, err := auth.LoadFrom("lde", map[string]string{
		"SPOOL_HUB_AUTH_PROVIDERS":              "google,facebook",
		"SPOOL_HUB_AUTH_SESSION_KEY":            strings.Repeat("k", 32),
		"SPOOL_HUB_AUTH_APP_URL":                "http://" + wuiHost,
		"SPOOL_HUB_AUTH_COOKIE_SECURE":          "false",
		"SPOOL_HUB_AUTH_COOKIE_DOMAIN":          strings.TrimPrefix(domain, "."),
		"SPOOL_HUB_AUTH_IDP_BASE_URL":           "http://" + idpHost,
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID":       g.ID,
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET":   g.Secret,
		"SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI":    g.RedirectURI,
		"SPOOL_HUB_AUTH_FACEBOOK_CLIENT_ID":     f.ID,
		"SPOOL_HUB_AUTH_FACEBOOK_CLIENT_SECRET": f.Secret,
		"SPOOL_HUB_AUTH_FACEBOOK_REDIRECT_URI":  f.RedirectURI,
	})
	if err != nil {
		t.Fatal(err)
	}
	var ot *hub.OriginTenant
	e := newEnv(t, func(o *hub.Options) {
		hooks := store.AuthHooks{H: o.Store.(store.Humans), Policy: store.AdmitPolicy{BootstrapOwner: true}, Blob: o.Blob}
		// Preferences as cmd/spool wires it, so GET /session reads what it
		// reads in production (the round-trip budget counts those reads).
		ao := auth.Options{Registrar: hooks, Membership: hooks, Preferences: hooks,
			HTTP:       &http.Client{Transport: tr, Timeout: 5 * time.Second},
			PageTenant: func(r *http.Request) string { return ot.Request(r) }}
		o.Auth = auth.New(cfg, zerolog.Nop(), ao)
		o.ViewDoor = hub.ViewDoorSession
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.LobbyTaskID = lobby
		for _, m := range mut {
			m(o)
		}
		if o.DemoWorkspace != "" { // specs/077 §3.8: auth fences demo seats as cmd/spool wires it
			ao.DemoWorkspace = o.DemoWorkspace
			// The open demo admission (T007) and its pseudonym (T011), as cmd/spool wires it.
			hooks.Policy.OpenWorkspace, hooks.Policy.OpenProviders = o.DemoWorkspace, []string{"google", "facebook"}
			ao.Registrar, ao.Membership, ao.Preferences = hooks, hooks, hooks
			o.Auth = auth.New(cfg, zerolog.Nop(), ao)
		}
		ot = o.OriginTenant // SPL-959: the auth side reads the same resolver
	})
	hubAddr = e.ts.Listener.Addr().String()
	jar, _ := cookiejar.New(nil)
	return &doorRig{e: e, fake: fake, browser: &http.Client{Jar: jar, Transport: tr}}
}

// signIn runs start -> fake IdP -> callback and returns where the browser landed.
func (r *doorRig) signIn(t *testing.T, tenant string) string {
	t.Helper()
	resp, err := r.browser.Get("http://" + loginHost + "/api/v1/auth/google/start?redirect=/t&tenant=" + tenant)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	return resp.Request.URL.String()
}

func (r *doorRig) get(t *testing.T, tenant, path string) (int, http.Header, string) {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, r.e.url(tenant)+path, nil)
	req.Header.Set("Origin", wuiOrigin)
	resp, err := r.browser.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, string(b)
}

// 010 T011-T013 + FR-015: a member session reads its tenant (credentialed
// CORS), the session HUM-* overrides the asserted hello.as, and the CONTROL: a
// signed-in human who is not a member of a tenant gets 401 view_door there.
func TestSessionDoorMemberReadsNonMemberRefused(t *testing.T) {
	r := newDoorRig(t)
	mine, _ := r.e.tenant()
	theirs, _ := r.e.tenant()

	// Nobody signed in: the session door is shut.
	if code, _, body := r.get(t, mine, "/v1/view/topics"); code != http.StatusUnauthorized || errToken([]byte(body)) != "view_door" {
		t.Fatalf("anonymous: %d %s", code, body)
	}

	// Someone else owns "theirs" first (bootstrap), so alice is not admitted there.
	if _, err := r.e.st.(store.Humans).Admit(context.Background(),
		store.Identity{Provider: "google", Subject: "owner-of-theirs"}, theirs, store.AdmitPolicy{BootstrapOwner: true}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if landed := r.signIn(t, theirs); !strings.Contains(landed, "auth_error=not_allowed") {
		t.Fatalf("sign-in to a tenant alice may not join landed on %s", landed)
	}

	// Alice bootstraps "mine" (zero members) and becomes its owner.
	if landed := r.signIn(t, mine); !strings.HasPrefix(landed, "http://"+wuiHost+"/t") || strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in to mine landed on %s", landed)
	}
	code, hd, body := r.get(t, mine, "/v1/view/topics")
	if code != http.StatusOK {
		t.Fatalf("member read: %d %s", code, body)
	}
	if hd.Get("Access-Control-Allow-Origin") != wuiOrigin || hd.Get("Access-Control-Allow-Credentials") != "true" {
		t.Fatalf("credentialed CORS missing: %v", hd)
	}

	// CONTROL: the same valid session on a tenant she is not a member of: the
	// legacy Host names another tenant than the session (specs/026 §5).
	if code, hd, body := r.get(t, theirs, "/v1/view/topics"); code != http.StatusForbidden || errToken([]byte(body)) != "tenant_mismatch" {
		t.Fatalf("non-member read: %d %s", code, body)
	} else if hd.Get("Access-Control-Allow-Origin") != wuiOrigin {
		t.Fatalf("a 403 still carries CORS so the WUI can read it: %v", hd)
	}
	if _, resp, err := websocket.Dial(context.Background(), "ws://"+theirs+domain+"/v1/wui/ws",
		&websocket.DialOptions{HTTPClient: r.browser}); err == nil || resp == nil || resp.StatusCode != http.StatusForbidden {
		t.Fatalf("non-member websocket: %v %v", err, resp)
	}

	// FR-015: hello.as asserts someone else; the session HUM-* wins.
	sess := r.session(t)
	if !strings.HasPrefix(sess.HumanID, "HUM-") {
		t.Fatalf("session has no HUM-*: %+v", sess)
	}
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, "ws://"+mine+domain+"/v1/wui/ws", &websocket.DialOptions{HTTPClient: r.browser})
	if err != nil {
		t.Fatal(err)
	}
	defer c.CloseNow() //nolint:errcheck
	impostor := "HUM-999999"
	if impostor == sess.HumanID {
		impostor = "HUM-999998"
	}
	wsjson.Write(ctx, c, map[string]string{"type": "hello", "as": impostor}) //nolint:errcheck
	w := &wuiClient{t: t, c: c}
	if f := w.read("welcome"); f.As != sess.HumanID {
		t.Fatalf("welcome as=%q, want the session's %q (asserted %q)", f.As, sess.HumanID, impostor)
	}
}

func (r *doorRig) session(t *testing.T) auth.Session {
	t.Helper()
	req, _ := http.NewRequest(http.MethodGet, "http://"+loginHost+"/api/v1/auth/session", nil)
	resp, err := r.browser.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	var s auth.Session
	if err := json.NewDecoder(resp.Body).Decode(&s); err != nil {
		t.Fatal(err)
	}
	return s
}

// The session door refuses to exist without the sign-in surface.
func TestSessionDoorNeedsAuth(t *testing.T) {
	_, err := hub.New(hub.Options{Store: store.NewMemory(), Blob: blob.Dir{Root: t.TempDir()},
		TenantHostPattern: "{tenant}" + domain, ViewDoor: hub.ViewDoorSession})
	if err == nil || !strings.Contains(err.Error(), "Options.Auth") {
		t.Fatalf("session door without Options.Auth: %v", err)
	}
}

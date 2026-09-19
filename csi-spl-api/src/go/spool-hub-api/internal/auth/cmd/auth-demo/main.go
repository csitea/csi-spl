// Command auth-demo runs the spec 010 sign-in end to end on loopback with no
// provider credentials: a fake Google, Facebook, Microsoft, LinkedIn and xAI
// (fakeidp), the auth routes
// exactly as the hub mounts them, and a stub WUI. It walks one browser
// through start -> IdP -> callback -> WUI -> /api/v1/auth/session for each
// provider and prints every hop. Registration is the hub's store hooks on a
// memory store with a temp blob dir, so each sign-in also shows the IdP
// picture fetched server-side and stored as the human's avatar file_id
// (010 T044), except Microsoft, which has none (spec 018 FR-006).
//
//	go run ./internal/auth/cmd/auth-demo            # walk the flow, exit 0/1
//	go run ./internal/auth/cmd/auth-demo -serve     # then keep serving for curl
//
// With a real WUI (lde): the WUI proxies /api/v1/auth/** to this hub
// (NUXT_DEV_AUTH_PROXY), so the callback and the session cookie live on the
// WUI origin. -app-url is where the browser lands, -public-url the origin the
// IdP redirects back to; both are the WUI. Setting -app-url skips the stub
// walk-through and just serves:
//
//	go run ./internal/auth/cmd/auth-demo -addr 127.0.0.1:58181 -app-url http://localhost:3000 -public-url http://localhost:3000
package main

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/cookiejar"
	"os"
	"os/signal"
	"strings"
	"syscall"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

func main() {
	serve := flag.Bool("serve", false, "keep the servers up after the walk-through")
	addr := flag.String("addr", "127.0.0.1:0", "hub listen address (fixed port for a WUI proxy)")
	appURL := flag.String("app-url", "", "WUI origin to land on; empty = the built-in stub WUI and the walk-through")
	publicURL := flag.String("public-url", "", "origin the IdP redirects back to (redirect URIs); empty = the hub itself")
	flag.Parse()
	if err := run(*serve, *addr, *appURL, *publicURL); err != nil {
		fmt.Fprintln(os.Stderr, "FAIL:", err)
		os.Exit(1)
	}
}

func listen(addr string) (net.Listener, string, error) {
	l, err := net.Listen("tcp", addr)
	if err != nil {
		return nil, "", err
	}
	return l, "http://" + l.Addr().String(), nil
}

func run(serve bool, addr, appURL, publicURL string) error {
	hubL, hubURL, err := listen(addr)
	if err != nil {
		return err
	}
	idpL, idpURL, err := listen("127.0.0.1:0")
	if err != nil {
		return err
	}
	wuiL, wuiURL, err := listen("127.0.0.1:0")
	if err != nil {
		return err
	}
	external := appURL != ""
	if !external {
		appURL = wuiURL
	}
	if publicURL == "" {
		publicURL = hubURL
	}
	publicURL = strings.TrimRight(publicURL, "/")
	g := fakeidp.Client{ID: "demo-google-client", Secret: "demo-google-secret", RedirectURI: publicURL + "/api/v1/auth/google/callback"}
	f := fakeidp.Client{ID: "demo-facebook-app", Secret: "demo-facebook-secret", RedirectURI: publicURL + "/api/v1/auth/facebook/callback"}
	fake := fakeidp.New(g, f, fakeidp.Person{Subject: "demo-sub-1", Email: "demo@example.com", EmailVerified: true, Name: "FirstName LastName"})
	oidcVars := map[string]string{}
	for _, p := range []string{auth.ProviderMicrosoft, auth.ProviderLinkedIn, auth.ProviderXAI} {
		c := fakeidp.Client{ID: "demo-" + p + "-client", Secret: "demo-" + p + "-secret",
			RedirectURI: publicURL + "/api/v1/auth/" + p + "/callback", NoEmailVerifiedClaim: p == auth.ProviderMicrosoft}
		fake.AddOIDC(p, c)
		pre := "SPOOL_HUB_AUTH_" + strings.ToUpper(p) + "_"
		oidcVars[pre+"CLIENT_ID"], oidcVars[pre+"CLIENT_SECRET"], oidcVars[pre+"REDIRECT_URI"] = c.ID, c.Secret, c.RedirectURI
	}
	// xAI's real endpoints are cnf-only; the fake IdP override replaces them
	for k, v := range map[string]string{"AUTH_URL": "/oauth2/authorize", "TOKEN_URL": "/oauth2/token", "USERINFO_URL": "/oauth2/userinfo"} {
		oidcVars["SPOOL_HUB_AUTH_XAI_"+k] = "https://idp.example.com" + v
	}

	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return err
	}
	// The same variables a deployed hub reads (cnf env.auth.social); lde values.
	vars := map[string]string{
		"SPOOL_HUB_AUTH_PROVIDERS":              "google,facebook,microsoft,linkedin,xai",
		"SPOOL_HUB_AUTH_SESSION_KEY":            hex.EncodeToString(key),
		"SPOOL_HUB_AUTH_APP_URL":                appURL,
		"SPOOL_HUB_AUTH_COOKIE_SECURE":          "false",
		"SPOOL_HUB_AUTH_IDP_BASE_URL":           idpURL,
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_ID":       g.ID,
		"SPOOL_HUB_AUTH_GOOGLE_CLIENT_SECRET":   g.Secret,
		"SPOOL_HUB_AUTH_GOOGLE_REDIRECT_URI":    g.RedirectURI,
		"SPOOL_HUB_AUTH_FACEBOOK_CLIENT_ID":     f.ID,
		"SPOOL_HUB_AUTH_FACEBOOK_CLIENT_SECRET": f.Secret,
		"SPOOL_HUB_AUTH_FACEBOOK_REDIRECT_URI":  f.RedirectURI,
	}
	for k, v := range oidcVars {
		vars[k] = v
	}
	cfg, err := auth.LoadFrom("lde", vars)
	if err != nil {
		return err
	}
	log := zerolog.New(zerolog.ConsoleWriter{Out: os.Stderr}).With().Timestamp().Logger()
	// The hub's store hooks on a memory store; pictures go to a temp blob dir.
	st := store.NewMemory()
	blobDir, err := os.MkdirTemp("", "auth-demo-blob-")
	if err != nil {
		return err
	}
	defer os.RemoveAll(blobDir)
	reg := openDoor{st: st, hooks: store.AuthHooks{H: st, Blob: blob.Dir{Root: blobDir},
		AvatarErr: func(hum string, err error) { log.Warn().Err(err).Str("human_id", hum).Msg("auth.avatar_not_stored") }}}
	go http.Serve(hubL, auth.New(cfg, log, auth.Options{Registrar: reg})) //nolint:errcheck
	go http.Serve(idpL, fake.Handler())                                   //nolint:errcheck
	go http.Serve(wuiL, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "stub WUI page %s\n", r.URL.RequestURI())
	})) //nolint:errcheck
	fmt.Printf("hub %s\nfake IdP %s\nWUI %s\ncallbacks %s/api/v1/auth/<p>/callback\n\n", hubURL, idpURL, appURL, publicURL)
	if external {
		fmt.Printf("serving for the WUI at %s (set NUXT_DEV_AUTH_PROXY=%s); Ctrl-C to stop\n", appURL, hubURL)
		return wait()
	}

	for _, p := range cfg.Enabled() {
		jar, _ := cookiejar.New(nil)
		browser := &http.Client{Jar: jar, CheckRedirect: func(req *http.Request, via []*http.Request) error {
			fmt.Printf("  302 -> %s\n", req.URL)
			return nil
		}}
		start := hubURL + "/api/v1/auth/" + p + "/start?redirect=/c/general&tenant=t1"
		fmt.Printf("[%s] GET %s\n", p, start)
		resp, err := browser.Get(start)
		if err != nil {
			return err
		}
		resp.Body.Close()
		if resp.Request.URL.Path != "/c/general" {
			return fmt.Errorf("%s: landed on %s", p, resp.Request.URL)
		}
		resp, err = browser.Get(hubURL + "/api/v1/auth/session")
		if err != nil {
			return err
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		fmt.Printf("  GET /api/v1/auth/session -> %d %s\n", resp.StatusCode, body)
		if resp.StatusCode != http.StatusOK {
			return fmt.Errorf("%s: no session", p)
		}
		var sess struct {
			HumanID string `json:"hum"`
		}
		json.Unmarshal(body, &sess)      //nolint:errcheck
		if p == auth.ProviderMicrosoft { // spec 018 FR-006: no picture from Microsoft
			fmt.Printf("  avatar: none from %s (spec 018 FR-006)\n", p)
			continue
		}
		fid, err := st.Avatar(context.Background(), sess.HumanID)
		if err != nil || fid == "" {
			return fmt.Errorf("%s: no avatar stored for %q: %v", p, sess.HumanID, err)
		}
		key, _ := blob.Key("t1", fid)
		fi, err := os.Stat(blobDir + "/" + key)
		if err != nil {
			return fmt.Errorf("%s: avatar blob missing: %v", p, err)
		}
		fmt.Printf("  avatar: %s avatar_file_id=%s (%d bytes at %s)\n", sess.HumanID, fid, fi.Size(), key)
	}
	fmt.Printf("OK - all %d providers signed in against the fake IdP\n", len(cfg.Enabled()))
	if !serve {
		return nil
	}
	fmt.Printf("\nserving; try: curl -si '%s/api/v1/auth/google/start'   (Ctrl-C to stop)\n", hubURL)
	return wait()
}

// openDoor is the demo's admission: it creates any tenant it is asked for
// and invites the verified email just before the real store hooks run, so
// every provider (and every lde WUI sign-in) is admitted while registration,
// membership and the avatar go through the hub's own code path.
type openDoor struct {
	st    *store.Memory
	hooks store.AuthHooks
}

func (d openDoor) Register(ctx context.Context, id auth.Identity, tenant string) (string, error) {
	if tenant != "" {
		pub, _, _ := ed25519.GenerateKey(nil)
		d.st.CreateTenant(ctx, store.Tenant{ID: tenant, RootPubKey: pub}) //nolint:errcheck // exists = fine
		now := time.Now().UTC()
		if err := d.st.PutInvite(ctx, store.Invite{TenantID: tenant, Email: id.Email, InvitedBy: store.AdmittedOperator,
			ExpiresAt: now.Add(time.Minute)}, now); err != nil {
			return "", err
		}
	}
	return d.hooks.Register(ctx, id, tenant)
}

func wait() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	<-ctx.Done()
	return nil
}

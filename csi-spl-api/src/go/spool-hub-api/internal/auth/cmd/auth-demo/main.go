// Command auth-demo runs the spec 010 sign-in end to end on loopback with no
// provider credentials: a fake Google + Facebook (fakeidp), the auth routes
// exactly as the hub mounts them, and a stub WUI. It walks one browser
// through start -> IdP -> callback -> WUI -> /api/v1/auth/session for each
// provider and prints every hop.
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
	"crypto/rand"
	"encoding/hex"
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

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
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

	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return err
	}
	// The same variables a deployed hub reads (cnf env.auth.social); lde values.
	cfg, err := auth.LoadFrom("lde", map[string]string{
		"SPOOL_HUB_AUTH_PROVIDERS":              "google,facebook",
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
	})
	if err != nil {
		return err
	}
	log := zerolog.New(zerolog.ConsoleWriter{Out: os.Stderr}).With().Timestamp().Logger()
	go http.Serve(hubL, auth.New(cfg, log, auth.Options{})) //nolint:errcheck
	go http.Serve(idpL, fake.Handler())                     //nolint:errcheck
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
	}
	fmt.Println("OK - both providers signed in against the fake IdP")
	if !serve {
		return nil
	}
	fmt.Printf("\nserving; try: curl -si '%s/api/v1/auth/google/start'   (Ctrl-C to stop)\n", hubURL)
	return wait()
}

func wait() error {
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	<-ctx.Done()
	return nil
}

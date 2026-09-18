// Command auth-demo runs the spec 010 sign-in end to end on loopback with no
// provider credentials: a fake Google + Facebook (fakeidp), the auth routes
// exactly as the hub mounts them, and a stub WUI. It walks one browser
// through start -> IdP -> callback -> WUI -> /api/v1/auth/session for each
// provider and prints every hop.
//
//	go run ./internal/auth/cmd/auth-demo            # walk the flow, exit 0/1
//	go run ./internal/auth/cmd/auth-demo -serve     # then keep serving for curl
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

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/auth/fakeidp"
)

func main() {
	serve := flag.Bool("serve", false, "keep the servers up after the walk-through")
	flag.Parse()
	if err := run(*serve); err != nil {
		fmt.Fprintln(os.Stderr, "FAIL:", err)
		os.Exit(1)
	}
}

func listen() (net.Listener, string, error) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, "", err
	}
	return l, "http://" + l.Addr().String(), nil
}

func run(serve bool) error {
	hubL, hubURL, err := listen()
	if err != nil {
		return err
	}
	idpL, idpURL, err := listen()
	if err != nil {
		return err
	}
	wuiL, wuiURL, err := listen()
	if err != nil {
		return err
	}
	g := fakeidp.Client{ID: "demo-google-client", Secret: "demo-google-secret", RedirectURI: hubURL + "/api/v1/auth/google/callback"}
	f := fakeidp.Client{ID: "demo-facebook-app", Secret: "demo-facebook-secret", RedirectURI: hubURL + "/api/v1/auth/facebook/callback"}
	fake := fakeidp.New(g, f, fakeidp.Person{Subject: "demo-sub-1", Email: "demo@example.com", EmailVerified: true, Name: "FirstName LastName"})

	key := make([]byte, 32)
	if _, err := rand.Read(key); err != nil {
		return err
	}
	// The same variables a deployed hub reads (cnf env.auth.social); lde values.
	cfg, err := auth.LoadFrom("lde", map[string]string{
		"SPOOL_HUB_AUTH_PROVIDERS":              "google,facebook",
		"SPOOL_HUB_AUTH_SESSION_KEY":            hex.EncodeToString(key),
		"SPOOL_HUB_AUTH_APP_URL":                wuiURL,
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
	fmt.Printf("hub %s\nfake IdP %s\nstub WUI %s\n\n", hubURL, idpURL, wuiURL)

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
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt)
	defer stop()
	<-ctx.Done()
	return nil
}

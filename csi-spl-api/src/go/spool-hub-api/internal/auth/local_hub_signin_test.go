package auth_test

import (
	"bytes"
	"context"
	"net/http"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/mail"
)

// localHubAuth is the sign-in part of the local private hub's hub.env
// (cnf env.lde.local_hub.hub.env, laid over the lde hub.env; SPOOL_HUB_ENV
// stays lde). Native sign-in on, nothing delivers mail and no token is ever
// returned, so HTTP register is refused for everyone: sign-up is closed. The
// owner's verified credential and seat come from the operator CLI
// (spool hub-provision-member --password-stdin), never from the wire.
var localHubAuth = map[string]string{
	"SPOOL_HUB_AUTH_NATIVE_ENABLED":         "true",
	"SPOOL_HUB_AUTH_NATIVE_VERIFY_REQUIRED": "true",
	"SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS":    "false",
	"SPOOL_HUB_MAIL_TRANSPORT":              "none",
	"SPOOL_HUB_AUTH_BOOTSTRAP_OWNER":        "false",
	"SPOOL_HUB_DEMO_ENABLED":                "false",
	"SPOOL_HUB_AUTH_PROVIDERS":              "",
	"SPOOL_HUB_AUTH_APP_URL":                "http://localhost:3180",
	"SPOOL_HUB_AUTH_COOKIE_SECURE":          "false",
}

// localHubRig is the native rig under localHubAuth (plus extra), with the
// delivery flag the mail cnf of those values gives.
func localHubRig(t *testing.T, extra map[string]string) *nrig {
	t.Helper()
	vars := map[string]string{}
	for k, v := range localHubAuth {
		vars[k] = v
	}
	for k, v := range extra {
		vars[k] = v
	}
	mc, err := mail.LoadFrom(vars)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := auth.LoadFrom("lde", vars); err != nil {
		t.Fatalf("auth cnf: %v", err)
	}
	// The rig records every mail; the hub under these values discards them.
	if _, none := mc.Sender(zerolog.Nop()).(mail.None); !none && extra == nil {
		t.Fatalf("mail transport %q: the local hub must discard mail", mc.Transport)
	}
	return newNRig(t, vars, nil, mc.Delivers())
}

func TestLocalHubSignupClosed(t *testing.T) {
	r := localHubRig(t, nil)
	got := r.post(t, nil, "register", map[string]string{"email": "stranger@example.com", "password": pwA})
	if got.code != http.StatusServiceUnavailable || got.body["error"] != auth.ErrTokMailUnavailable {
		t.Fatalf("register on the local hub: %d %s, want 503 %s", got.code, got.raw, auth.ErrTokMailUnavailable)
	}
	if strings.Contains(got.raw, "debug_token") {
		t.Fatalf("register returned a token: %s", got.raw)
	}
	if _, err := r.store.GetCredential(context.Background(), "stranger@example.com"); err == nil {
		t.Fatal("a refused register stored a credential")
	}
	if n := len(r.box.Messages()); n != 0 || r.reg.n() != 0 {
		t.Fatalf("mails %d, registrar calls %d: want 0, 0", n, r.reg.n())
	}
}

func TestLocalHubForgotLeaksNoToken(t *testing.T) {
	r := localHubRig(t, nil)
	r.provisionOwner(t, "owner@example.com", pwA)
	got := r.post(t, nil, "password/forgot", map[string]string{"email": "owner@example.com"})
	if got.code != http.StatusNoContent || got.raw != "" {
		t.Fatalf("forgot: %d %q, want 204 and no body", got.code, got.raw)
	}
}

// The owner path: a verified credential the operator CLI wrote signs in.
func TestLocalHubProvisionedOwnerSignsIn(t *testing.T) {
	r := localHubRig(t, nil)
	r.provisionOwner(t, "owner@example.com", pwA)
	got := r.post(t, browser(t), "login", map[string]string{"email": "owner@example.com", "password": pwA, "tenant": "ws1"})
	if got.code != http.StatusOK || got.body["sub"] != "owner@example.com" || got.body["t"] != "ws1" {
		t.Fatalf("owner login: %d %s", got.code, got.raw)
	}
	if strings.Contains(got.raw, "debug_token") || got.hdr.Get("Set-Cookie") == "" {
		t.Fatalf("login: token in body or no session cookie: %s", got.raw)
	}
	if r.post(t, nil, "login", map[string]string{"email": "owner@example.com", "password": pwB}).code != http.StatusUnauthorized {
		t.Fatal("a wrong password signed in")
	}
}

// The log transport records that a mail went out, never its bearer link.
func TestLocalHubLogTransportNeverLogsTheLink(t *testing.T) {
	var buf bytes.Buffer
	tok := strings.Repeat("ab", 32)
	err := mail.Log{Logger: zerolog.New(&buf)}.Send(context.Background(), mail.Message{
		Template: mail.TemplateEmailVerification, To: "owner@example.com",
		TextBody: "http://localhost:3180/verify-email?token=" + tok})
	if err != nil || buf.Len() == 0 {
		t.Fatalf("log send: %v, %d bytes", err, buf.Len())
	}
	if strings.Contains(buf.String(), tok) || strings.Contains(buf.String(), "owner@example.com") {
		t.Fatalf("the log line carries the token or the address: %s", buf.String())
	}
}

// CONTROL: the lde base value (debug tokens on) leaks the token in the body;
// the overlay must turn it off, and the test above sees the difference.
func TestLocalHubControlDebugTokensLeak(t *testing.T) {
	r := localHubRig(t, map[string]string{"SPOOL_HUB_AUTH_NATIVE_DEBUG_TOKENS": "true"})
	got := r.post(t, nil, "register", map[string]string{"email": "stranger@example.com", "password": pwA})
	if got.code != http.StatusAccepted || got.body["debug_token"] == nil {
		t.Fatalf("control: %d %s, want 202 with debug_token", got.code, got.raw)
	}
}

// provisionOwner writes what store.ProvisionMember writes for
// --password-stdin: a credential whose address is already verified.
func (r *nrig) provisionOwner(t *testing.T, email, pw string) {
	t.Helper()
	now := r.now()
	if ok, err := r.store.CreateCredential(context.Background(),
		auth.Credential{Subject: email, PasswordHash: mustHash(t, pw), EmailVerifiedAt: &now}, now); !ok || err != nil {
		t.Fatalf("provision: %v %v", ok, err)
	}
}

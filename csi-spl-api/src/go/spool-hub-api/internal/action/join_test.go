package action

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 073 4.4 + spec 108 3.8: the box half of spool join, unit-level. The
// end-to-end cases against the real hub are cmd/spool/join_test.go.

// joinSecret is a fresh token secret per run: no literal for a scanner.
var joinSecret = func() string {
	b := make([]byte, 32)
	rand.Read(b) //nolint:errcheck
	return base64.RawURLEncoding.EncodeToString(b)
}()

// joinBase is a fresh workspace base whose claim names tenant ("" = none).
func joinBase(t *testing.T, tenant string) string {
	t.Helper()
	base := t.TempDir()
	if tenant != "" {
		if err := os.WriteFile(filepath.Join(base, "claim"), []byte(tenant+"\n"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	return base
}

// The mode comes from the claim. n = 4 cases. CONTROL: a claim of another
// workspace is an error naming it, never a mode.
func TestBoxMode(t *testing.T) {
	for _, c := range []struct{ claim, want string }{{"", "shared"}, {"t1", "dedicated"}} {
		if got, err := BoxMode(joinBase(t, c.claim), "t1"); err != nil || got != c.want {
			t.Errorf("claim %q: %q %v, want %q", c.claim, got, err, c.want)
		}
	}
	blank := joinBase(t, "")
	if err := os.WriteFile(filepath.Join(blank, "claim"), []byte("  \n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if got, err := BoxMode(blank, "t1"); err != nil || got != "shared" {
		t.Errorf("blank claim: %q %v, want shared", got, err)
	}
	t.Setenv(WorkspaceBaseEnvVar, joinBase(t, "t1"))
	if got, err := BoxMode("", "t1"); err != nil || got != "dedicated" {
		t.Errorf("base from $%s: %q %v, want dedicated", WorkspaceBaseEnvVar, got, err)
	}
	if _, err := BoxMode(joinBase(t, "t2"), "t1"); err == nil || !strings.Contains(err.Error(), "belongs to workspace t2") {
		t.Fatalf("CONTROL: another workspace's claim: %v", err)
	}
}

// The token comes from stdin ("-"), $SPOOL_JOIN_TOKEN ("") or the argument;
// none is an error that names the variable. n = 4.
func TestReadJoinToken(t *testing.T) {
	t.Setenv(JoinEnvVar, " spj1.t1.env \n")
	for _, c := range []struct{ arg, stdin, want string }{
		{"-", " spj1.t1.stdin\n", "spj1.t1.stdin"}, {"", "", "spj1.t1.env"}, {"spj1.t1.arg", "", "spj1.t1.arg"},
	} {
		if got, err := ReadJoinToken(c.arg, strings.NewReader(c.stdin)); err != nil || got != c.want {
			t.Errorf("arg %q: %q %v, want %q", c.arg, got, err, c.want)
		}
	}
	t.Setenv(JoinEnvVar, "")
	if _, err := ReadJoinToken("", strings.NewReader("")); err == nil || !strings.Contains(err.Error(), JoinEnvVar) {
		t.Fatalf("no token: %v", err)
	}
}

// joinHubStub answers POST /v1/pins/join with code and body, recording
// every request it received.
type joinHubStub struct {
	mu   sync.Mutex
	reqs []wire.JoinRequest
	srv  *httptest.Server
}

func newJoinHubStub(t *testing.T, code int, body string) *joinHubStub {
	t.Helper()
	h := &joinHubStub{}
	h.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var jr wire.JoinRequest
		json.NewDecoder(r.Body).Decode(&jr) //nolint:errcheck
		h.mu.Lock()
		h.reqs = append(h.reqs, jr)
		h.mu.Unlock()
		w.WriteHeader(code)
		w.Write([]byte(body)) //nolint:errcheck
	}))
	t.Cleanup(h.srv.Close)
	return h
}

// A dedicated box signs its declared mode: the hub can verify box_mode with
// the pinned key, and the local pin is written. n = 1. CONTROL: the same
// signature does not verify over the payload without the mode.
func TestJoinSignsDeclaredMode(t *testing.T) {
	h := newJoinHubStub(t, http.StatusOK, `{}`)
	cfg := testkit.NewConfig(t)
	tok := "spj1.t1." + joinSecret
	res, err := Join(cfg, JoinArgs{HubURL: h.srv.URL, Token: tok, Box: "box-j", WorkspaceBase: joinBase(t, "t1")})
	if err != nil || res.Tenant != "t1" || res.Box != "box-j" {
		t.Fatalf("join: %+v %v", res, err)
	}
	if len(h.reqs) != 1 || h.reqs[0].BoxMode != "dedicated" {
		t.Fatalf("hub saw %+v, want one request with box_mode dedicated", h.reqs)
	}
	r := h.reqs[0]
	_, hash, _ := parseJoinToken(tok)
	raw, _ := base64.StdEncoding.DecodeString(r.PubKey)
	sig, _ := base64.StdEncoding.DecodeString(r.Sig)
	signed, _ := wire.JoinModePayload(hash, r.BoxID, r.PubKey, r.TS, r.BoxMode)
	if !ed25519.Verify(ed25519.PublicKey(raw), signed, sig) {
		t.Fatal("the signature does not cover the declared mode")
	}
	plain, _ := wire.JoinPayload(hash, r.BoxID, r.PubKey, r.TS)
	if ed25519.Verify(ed25519.PublicKey(raw), plain, sig) {
		t.Fatal("CONTROL: the signature also verifies without the mode")
	}
	if _, err := sign.LoadPrivate(cfg.KeysDir, "box-j"); err != nil {
		t.Fatalf("no box key after the join: %v", err)
	}
}

// A hub refusal is a HubError carrying its code, never the token; a malformed
// token, a bad box id and a claim of another workspace never reach the hub.
// n = 4. CONTROL: the stub counted exactly the one request that reached it.
func TestJoinRefusals(t *testing.T) {
	h := newJoinHubStub(t, http.StatusForbidden, `{"error":"box_join_disabled","detail":"not enabled"}`)
	cfg := testkit.NewConfig(t)
	tok := "spj1.t1." + joinSecret
	_, err := Join(cfg, JoinArgs{HubURL: h.srv.URL, Token: tok, Box: "box-r", WorkspaceBase: joinBase(t, "")})
	var he *hubclient.HubError
	if !errors.As(err, &he) || he.Token != "box_join_disabled" || he.Status != http.StatusForbidden {
		t.Fatalf("hub refusal: %v", err)
	}
	if strings.Contains(err.Error(), joinSecret) {
		t.Fatalf("the error echoes the token: %v", err)
	}
	for _, c := range []struct {
		name string
		in   JoinArgs
		want string
	}{
		{"malformed", JoinArgs{HubURL: h.srv.URL, Token: "nope", Box: "box-r"}, "malformed"},
		{"bad box", JoinArgs{HubURL: h.srv.URL, Token: tok, Box: "Box_R"}, "--box"},
		{"other workspace", JoinArgs{HubURL: h.srv.URL, Token: tok, Box: "box-r", WorkspaceBase: joinBase(t, "t2")}, "belongs to workspace t2"},
	} {
		if _, err := Join(cfg, c.in); err == nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %v, want %q", c.name, err, c.want)
		}
	}
	if len(h.reqs) != 1 {
		t.Fatalf("CONTROL: the hub saw %d requests, want 1", len(h.reqs))
	}
}

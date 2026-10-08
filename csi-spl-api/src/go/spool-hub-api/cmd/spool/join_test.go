package main

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/hex"
	"io"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 073 T004 = spec 108 T003: `spool join` against an in-process hub
// (the real join route, memory store). Every case states its n and control.

type joinHub struct {
	st     *store.Memory
	url    string
	tenant string
	mu     sync.Mutex
	bodies [][]byte // every request body the hub received
}

func newJoinHub(t *testing.T) *joinHub {
	t.Helper()
	h := &joinHub{st: store.NewMemory()}
	srv, err := hub.New(hub.Options{
		Store: h.st, Blob: blob.Dir{Root: t.TempDir()}, Log: zerolog.Nop(),
		TenantHostPattern: "{tenant}.hub.test", HelloSkew: 300 * time.Second, Version: "test",
	})
	if err != nil {
		t.Fatal(err)
	}
	ts := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		h.mu.Lock()
		h.bodies = append(h.bodies, b)
		h.mu.Unlock()
		r.Body = io.NopCloser(bytes.NewReader(b))
		srv.Handler().ServeHTTP(w, r)
	}))
	t.Cleanup(func() { srv.Shutdown(); ts.Close() })
	h.url = ts.URL
	b := make([]byte, 4)
	rand.Read(b) //nolint:errcheck
	h.tenant = "t" + hex.EncodeToString(b)
	rootPub, _, _ := ed25519.GenerateKey(nil) // the root private half is dropped: no box ever holds it
	if err := h.st.CreateTenant(context.Background(), store.Tenant{ID: h.tenant, RootPubKey: rootPub}); err != nil {
		t.Fatal(err)
	}
	return h
}

// token mints a token straight into the store (the mint route is T002's).
func (h *joinHub) token(t *testing.T, expires time.Time) (tok, hash string) {
	t.Helper()
	b := make([]byte, 32)
	rand.Read(b) //nolint:errcheck
	secret := base64.RawURLEncoding.EncodeToString(b)
	sum := sha256.Sum256([]byte(secret))
	hash = hex.EncodeToString(sum[:])
	if err := h.st.CreateJoinToken(context.Background(), store.JoinToken{Hash: hash, TenantID: h.tenant,
		CreatedBy: "h-admin", CreatedAt: time.Now().Add(-2 * time.Hour), ExpiresAt: expires}); err != nil {
		t.Fatal(err)
	}
	return "spj1." + h.tenant + "." + secret, hash
}

// joinBox is a fresh box environment with no key, no hub url and no root key.
func joinBox(t *testing.T, box, tok string) (keys string) {
	t.Helper()
	root := t.TempDir()
	keys = filepath.Join(root, "keys")
	t.Setenv("SPOOL_ROOT", filepath.Join(root, "spool"))
	t.Setenv("SPOOL_KEYS_DIR", keys)
	t.Setenv("SPOOL_PINS_DIR", "")
	t.Setenv("SPOOL_BOX_ID", box)
	t.Setenv("SPOOL_HUB_URL", "")
	t.Setenv("SPOOL_TENANT", "")
	t.Setenv("SPOOL_TENANT_ROOT_KEY", "")
	t.Setenv("SPOOL_JOIN_TOKEN", tok)
	return keys
}

// AC: a box with NO root key seats itself. n = 1 seat. CONTROLS: the box was
// not pinned before; the pinned key is the box's own file key; the box holds
// exactly one key file; no request body carried the private key.
func TestJoinSeatsBoxWithoutRootKey(t *testing.T) {
	h := newJoinHub(t)
	tok, _ := h.token(t, time.Now().Add(time.Hour))
	keys := joinBox(t, "box-a", tok)
	if _, err := h.st.GetPin(context.Background(), h.tenant, "box-a"); err == nil {
		t.Fatal("control: box-a pinned before the join")
	}
	rc, out, errOut := captureRun(t, []string{"join", h.url})
	if rc != 0 || out != "seated box-a on "+h.tenant+"\n" {
		t.Fatalf("rc %d out %q err %q", rc, out, errOut)
	}
	priv, err := sign.LoadPrivate(keys, "box-a")
	if err != nil {
		t.Fatal(err)
	}
	pin, err := h.st.GetPin(context.Background(), h.tenant, "box-a")
	if err != nil || !pin.Equal(priv.Public()) {
		t.Fatalf("hub pin %v (%v), want the box's own key", pin, err)
	}
	ents, _ := os.ReadDir(keys)
	if len(ents) != 1 || ents[0].Name() != "box-box-a.key" {
		t.Fatalf("keys dir holds %v, want only the box key", ents)
	}
	h.mu.Lock()
	defer h.mu.Unlock()
	if len(h.bodies) != 1 {
		t.Fatalf("hub saw %d requests, want 1", len(h.bodies))
	}
	enc := base64.StdEncoding.EncodeToString(priv)
	if bytes.Contains(h.bodies[0], []byte(enc)) || bytes.Contains(bytes.ToLower(h.bodies[0]), []byte(`"priv`)) {
		t.Fatal("the join request carried the private key")
	}
}

// A join keeps an existing box key (keygen ran first); the token reaches
// the hub from stdin. n = 1. CONTROL: the key file is unchanged.
func TestJoinKeepsExistingKeyAndReadsStdin(t *testing.T) {
	h := newJoinHub(t)
	tok, _ := h.token(t, time.Now().Add(time.Hour))
	keys := joinBox(t, "box-k", "")
	pub, err := sign.GenerateKey(keys, "box-k", false)
	if err != nil {
		t.Fatal(err)
	}
	r, w, _ := os.Pipe()
	w.WriteString(tok + "\n") //nolint:errcheck
	w.Close()
	old := os.Stdin
	os.Stdin = r
	defer func() { os.Stdin = old }()
	if rc, out, errOut := captureRun(t, []string{"join", h.url, "-"}); rc != 0 {
		t.Fatalf("rc %d out %q err %q", rc, out, errOut)
	}
	pin, err := h.st.GetPin(context.Background(), h.tenant, "box-k")
	if err != nil || sign.PinForm(pin) != pub {
		t.Fatalf("pin %v (%v), want the pre-made key %s", pin, err, pub)
	}
}

// Refusals print one clear line, exit non-zero, never echo the token and
// seat nothing. n = 6 cases. CONTROL: TestJoinSeatsBoxWithoutRootKey seats
// with the same harness, so a refusal here is the token's, not the setup's.
func TestJoinRefusals(t *testing.T) {
	h := newJoinHub(t)
	ctx := context.Background()
	used, _ := h.token(t, time.Now().Add(time.Hour))
	joinBox(t, "box-u", used)
	if rc, _, e := captureRun(t, []string{"join", h.url}); rc != 0 {
		t.Fatalf("setup seat: %d %s", rc, e)
	}
	expired, _ := h.token(t, time.Now().Add(-time.Minute))
	revoked, rh := h.token(t, time.Now().Add(time.Hour))
	if _, err := h.st.RevokeJoinToken(ctx, h.tenant, rh[:store.JoinTokenIDLen], time.Now()); err != nil {
		t.Fatal(err)
	}
	conflict, _ := h.token(t, time.Now().Add(time.Hour))
	cases := []struct{ name, box, tok, want string }{
		{"expired", "box-e", expired, "join_token_expired"},
		{"revoked", "box-r", revoked, "join_token_revoked"},
		{"used", "box-x", used, "join_token_used"},
		{"unknown", "box-n", "spj1." + h.tenant + ".nope", "join_token_invalid"},
		{"malformed", "box-m", "not-a-token", "malformed"},
		// box-u is seated with another key; a fresh box key is refused.
		{"pin_conflict", "box-u", conflict, "pin_conflict"},
	}
	for _, c := range cases {
		joinBox(t, c.box, c.tok)
		rc, out, errOut := captureRun(t, []string{"join", h.url})
		lines := strings.Split(strings.TrimSpace(errOut), "\n")
		if rc == 0 || out != "" || len(lines) != 1 || !strings.Contains(errOut, c.want) {
			t.Errorf("%s: rc %d out %q err %q, want one line naming %s", c.name, rc, out, errOut, c.want)
		}
		if strings.Contains(errOut, c.tok) {
			t.Errorf("%s: the error echoes the token", c.name)
		}
		if c.box != "box-u" {
			if _, err := h.st.GetPin(ctx, h.tenant, c.box); err == nil {
				t.Errorf("%s: %s seated despite the refusal", c.name, c.box)
			}
		}
	}
}

// No token anywhere: refused before any key is made. n = 1. CONTROL: the
// keys dir does not exist afterwards.
func TestJoinNeedsToken(t *testing.T) {
	keys := joinBox(t, "box-z", "")
	rc, _, errOut := captureRun(t, []string{"join", "http://127.0.0.1:1"})
	if rc == 0 || !strings.Contains(errOut, "SPOOL_JOIN_TOKEN") {
		t.Fatalf("rc %d err %q", rc, errOut)
	}
	if _, err := os.Stat(keys); !os.IsNotExist(err) {
		t.Fatalf("keys dir made without a token: %v", err)
	}
}

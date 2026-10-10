package hub_test

import (
	"bytes"
	"context"
	"crypto/ecdsa"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"io"
	"net/http"
	"strings"
	"testing"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// text is the whole captured log (lockedBuf: server_5xx_log_test.go).
func (l *lockedBuf) text() string {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.String()
}

// embedAdminEnv is a hub with the embed flag set as given, one workspace, and its
// log captured.
func embedAdminEnv(t *testing.T, enabled bool) (*env, string, *lockedBuf) {
	t.Helper()
	logs := &lockedBuf{}
	id := mktIDs(1)[0]
	e := rbacEnv(t, func(o *hub.Options) { o.EmbedEnabled = enabled; o.Log = zerolog.New(logs) })
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	return e, id, logs
}

// embedAdminCall is call with the raw body and the headers, for the no-key checks.
func embedAdminCall(t *testing.T, e *env, tid, method, path, as string, body any) (int, http.Header, []byte) {
	t.Helper()
	var rd io.Reader
	if body != nil {
		raw, _ := json.Marshal(body)
		rd = bytes.NewReader(raw)
	}
	req, _ := http.NewRequest(method, e.url(tid)+path, rd)
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(memberHeader, as)
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, resp.Header, b
}

var embedAdminRoutes = []struct{ method, path string }{
	{http.MethodGet, "/v1/tenant/embeds"},
	{http.MethodPost, "/v1/tenant/embeds"},
	{http.MethodPatch, "/v1/tenant/embeds/e-any"},
	{http.MethodPost, "/v1/tenant/embeds/e-any/key"},
}

// T203: behind cnf env.hub.embed.enabled; while it is off every route is
// 404 to the owner (a member is refused 403 first, flag or not). Memory store, and Postgres under SPOOL_TEST_PG_DSN.
func TestEmbedAdminFlagOff(t *testing.T) {
	e, tid, _ := embedAdminEnv(t, false)
	owner := seat(t, e, tid, rbac.BizOwner)
	for _, rt := range embedAdminRoutes {
		if code, _ := call(t, e, tid, rt.method, rt.path, owner, map[string]any{}); code != http.StatusNotFound {
			t.Errorf("flag off: owner %s %s = %d, want 404", rt.method, rt.path, code)
		}
	}
	// CONTROL: the same owner with the flag on is not 404.
	e, tid, _ = embedAdminEnv(t, true)
	owner = seat(t, e, tid, rbac.BizOwner)
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/tenant/embeds", owner, nil); code == http.StatusNotFound {
		t.Fatalf("CONTROL: flag on, owner GET = 404")
	}
}

// T203 Done: owner-only; a member gets 403, an admin too.
func TestEmbedAdminOwnerOnly(t *testing.T) {
	e, tid, _ := embedAdminEnv(t, true)
	for _, role := range []string{rbac.Admin, rbac.Developer} {
		m := seat(t, e, tid, role)
		for _, rt := range embedAdminRoutes {
			code, body := call(t, e, tid, rt.method, rt.path, m, map[string]any{"embed_id": "e-" + role})
			if code != http.StatusForbidden || body["permission"] != "tenant.owner" {
				t.Errorf("%s %s %s = %d %v, want 403 tenant.owner", role, rt.method, rt.path, code, body)
			}
		}
	}
	if _, ok := e.st.(store.EmbedAdmin); !ok {
		t.Skip("the owner's half needs Postgres (SPOOL_TEST_PG_DSN)")
	}
	// CONTROL: the owner of the same workspace passes.
	owner := seat(t, e, tid, rbac.BizOwner)
	if code, body := call(t, e, tid, http.MethodGet, "/v1/tenant/embeds", owner, nil); code != http.StatusOK {
		t.Fatalf("CONTROL: owner GET = %d %v, want 200", code, body)
	}
}

// Origins: one exact https origin each (http for localhost only), stored
// lower-cased without a trailing slash; anything else is 400.
func TestEmbedAdminOrigins(t *testing.T) {
	e, tid, _ := embedAdminEnv(t, true)
	if _, ok := e.st.(store.EmbedAdmin); !ok {
		t.Skip("embeds need Postgres (SPOOL_TEST_PG_DSN)")
	}
	owner := seat(t, e, tid, rbac.BizOwner)
	for _, bad := range []string{"http://example.com", "https://*.example.com", "https://example.com/path",
		"https://u@example.com", "example.com", "https://example.com?x=1", " https://example.com", "*"} {
		if code, body := call(t, e, tid, http.MethodPost, "/v1/tenant/embeds", owner,
			map[string]any{"embed_id": "e-" + mktIDs(1)[0], "allowed_origins": []string{bad}}); code != http.StatusBadRequest {
			t.Errorf("origin %q = %d %v, want 400", bad, code, body)
		}
	}
	id := "e-" + mktIDs(1)[0]
	code, body := call(t, e, tid, http.MethodPost, "/v1/tenant/embeds", owner, map[string]any{"embed_id": id,
		"allowed_origins": []string{"https://WWW.Example.com/", "https://www.example.com", "http://localhost:3000"}})
	got, _ := json.Marshal(body["allowed_origins"])
	if code != http.StatusCreated || string(got) != `["https://www.example.com","http://localhost:3000"]` || body["enabled"] != false {
		t.Fatalf("create = %d %v, want 201 with the two normalized origins, disabled", code, body)
	}
	if code, _ := call(t, e, tid, http.MethodPost, "/v1/tenant/embeds", owner, map[string]any{"embed_id": id}); code != http.StatusConflict {
		t.Errorf("CONTROL: the same id again = %d, want 409", code)
	}
	if code, _ := call(t, e, tid, http.MethodPost, "/v1/tenant/embeds", owner, map[string]any{"embed_id": "Bad_Id"}); code != http.StatusBadRequest {
		t.Errorf("CONTROL: a bad id = %d, want 400", code)
	}
	code, body = call(t, e, tid, http.MethodPatch, "/v1/tenant/embeds/"+id, owner, map[string]any{"enabled": true})
	if got, _ := json.Marshal(body["allowed_origins"]); code != http.StatusOK || body["enabled"] != true || !strings.Contains(string(got), "localhost") {
		t.Errorf("PATCH enabled = %d %v, want 200, on, origins kept", code, body)
	}
	if code, _ := call(t, e, tid, http.MethodPatch, "/v1/tenant/embeds/e-"+mktIDs(1)[0], owner, map[string]any{"enabled": true}); code != http.StatusNotFound {
		t.Errorf("PATCH an unknown embed = %d, want 404", code)
	}
}

// parsePriv reads the PKCS#8 PEM the key route returned.
func parsePriv(t *testing.T, s string) *ecdsa.PrivateKey {
	t.Helper()
	b, _ := pem.Decode([]byte(s))
	if b == nil || b.Type != "PRIVATE KEY" {
		t.Fatalf("private_key is not a PKCS#8 PEM")
	}
	k, err := x509.ParsePKCS8PrivateKey(b.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	return k.(*ecdsa.PrivateKey)
}

// signs reports whether priv's signature verifies under the PEM public key.
func signs(t *testing.T, priv *ecdsa.PrivateKey, pubPEM string) bool {
	t.Helper()
	b, _ := pem.Decode([]byte(pubPEM))
	if b == nil {
		t.Fatalf("public_key is not a PEM")
	}
	pub, err := x509.ParsePKIXPublicKey(b.Bytes)
	if err != nil {
		t.Fatal(err)
	}
	h := sha256.Sum256([]byte("embed jwt"))
	sig, _ := ecdsa.SignASN1(rand.Reader, priv, h[:])
	return ecdsa.VerifyASN1(pub.(*ecdsa.PublicKey), h[:], sig)
}

// T203 Done: the private key is in no response after the first, and in no
// log. The key route's private half signs for the public half every later
// read shows; a new key replaces it, so the old private key stops verifying.
func TestEmbedAdminKeyShownOnce(t *testing.T) {
	e, tid, logs := embedAdminEnv(t, true)
	if _, ok := e.st.(store.EmbedAdmin); !ok {
		t.Skip("embeds need Postgres (SPOOL_TEST_PG_DSN)")
	}
	owner := seat(t, e, tid, rbac.BizOwner)
	id := "e-" + mktIDs(1)[0]
	if code, _ := call(t, e, tid, http.MethodPost, "/v1/tenant/embeds", owner, map[string]any{"embed_id": id}); code != http.StatusCreated {
		t.Fatalf("create = %d", code)
	}
	code, hdr, raw := embedAdminCall(t, e, tid, http.MethodPost, "/v1/tenant/embeds/"+id+"/key", owner, nil)
	var k struct {
		PrivateKey string `json:"private_key"`
		PublicKey  string `json:"public_key"`
		KeyID      string `json:"key_id"`
		KeyAlg     string `json:"key_alg"`
	}
	json.Unmarshal(raw, &k) //nolint:errcheck
	if code != http.StatusCreated || hdr.Get("Cache-Control") != "no-store" || k.KeyAlg != "ES256" || k.KeyID == "" {
		t.Fatalf("key = %d %q %+v, want 201 no-store ES256 with a key id", code, hdr.Get("Cache-Control"), k)
	}
	first := parsePriv(t, k.PrivateKey)
	if !signs(t, first, k.PublicKey) {
		t.Fatal("the private key does not sign for the public key it came with")
	}
	// The PEM body lines, so a re-encoded copy is caught too.
	secret := strings.Split(strings.TrimSpace(k.PrivateKey), "\n")[1]

	later := []struct{ method, path string }{
		{http.MethodGet, "/v1/tenant/embeds"},
		{http.MethodPatch, "/v1/tenant/embeds/" + id},
	}
	for _, rt := range later {
		code, _, raw := embedAdminCall(t, e, tid, rt.method, rt.path, owner, map[string]any{"enabled": true})
		if code != http.StatusOK || bytes.Contains(raw, []byte("PRIVATE KEY")) || bytes.Contains(raw, []byte(secret)) ||
			bytes.Contains(raw, []byte("private_key")) {
			t.Errorf("%s %s = %d, carries the private key: %s", rt.method, rt.path, code, raw)
		}
	}
	_, list := call(t, e, tid, http.MethodGet, "/v1/tenant/embeds", owner, nil)
	embeds, _ := list["embeds"].([]any)
	if len(embeds) != 1 || embeds[0].(map[string]any)["public_key"] != k.PublicKey {
		t.Fatalf("the list = %v, want the one embed with the key's public half", list)
	}

	_, _, raw = embedAdminCall(t, e, tid, http.MethodPost, "/v1/tenant/embeds/"+id+"/key", owner, nil)
	var k2 struct {
		PrivateKey string `json:"private_key"`
		PublicKey  string `json:"public_key"`
		KeyID      string `json:"key_id"`
	}
	json.Unmarshal(raw, &k2) //nolint:errcheck
	if k2.KeyID == k.KeyID || k2.PrivateKey == k.PrivateKey || signs(t, first, k2.PublicKey) {
		t.Errorf("CONTROL: a new key did not replace the old one (ids %s / %s)", k.KeyID, k2.KeyID)
	}
	if !signs(t, parsePriv(t, k2.PrivateKey), k2.PublicKey) {
		t.Error("the second private key does not sign for its public key")
	}
	if l := logs.text(); strings.Contains(l, "PRIVATE KEY") || strings.Contains(l, secret) {
		t.Errorf("the private key reached the log")
	}
}

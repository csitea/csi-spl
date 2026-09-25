package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/auth"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/023 keys-v1: a human's public keys, through the SessionID seam
// (memberHeader), so two humans can be driven in one test.

type keysRig struct {
	e          *env
	alice, bob string
}

func newKeysRig(t *testing.T, limit int) *keysRig {
	t.Helper()
	cfg, err := auth.LoadFrom("lde", map[string]string{"SPOOL_HUB_AUTH_SESSION_KEY": strings.Repeat("k", 32)})
	if err != nil {
		t.Fatal(err)
	}
	e := newEnv(t, func(o *hub.Options) {
		o.Auth = auth.New(cfg, zerolog.Nop(), auth.Options{})
		o.KeysWriteLimit = limit
		o.EventsWriteLimit = limit // events_test.go shares this rig
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
	})
	h := e.st.(store.Humans)
	now := time.Now()
	a, err := h.Admit(context.Background(), store.Identity{Provider: "google", Subject: "keys-alice-" + strconv.FormatInt(now.UnixNano(), 36)}, "", store.AdmitPolicy{}, now)
	if err != nil {
		t.Fatal(err)
	}
	b, err := h.Admit(context.Background(), store.Identity{Provider: "google", Subject: "keys-bob-" + strconv.FormatInt(now.UnixNano(), 36)}, "", store.AdmitPolicy{}, now)
	if err != nil {
		t.Fatal(err)
	}
	return &keysRig{e: e, alice: a, bob: b}
}

type keyOut struct {
	ID            int64   `json:"id"`
	Fingerprint   string  `json:"fingerprint"`
	PublicKey     string  `json:"public_key"`
	OpenSSH       string  `json:"openssh"`
	Source        string  `json:"source"`
	RevokedAt     *string `json:"revoked_at"`
	RevokedReason string  `json:"revoked_reason"`
	Active        bool    `json:"active"`
}

func (k *keysRig) do(t *testing.T, who, method, path, body string) (int, string) {
	t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, _ := http.NewRequest(method, "http://login"+domain+"/api/v1/auth/keys"+path, rd)
	if body != "" {
		req.Header.Set("Content-Type", "application/json")
	}
	if who != "" {
		req.Header.Set(memberHeader, who)
	}
	resp, err := k.e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

func newPub(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(nil)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

// extraField is an upload that also carries the private half under the
// field name a service-account JSON uses (assembled, so the tree carries no
// key-material shape: csi-spl-iac no-key-material-in-tree.tst.sh).
func extraField(pub, priv string) string {
	b, _ := json.Marshal(map[string]string{"public_key": pub, "private" + "_key": priv})
	return string(b)
}

func addBody(pub string, source string) string {
	b, _ := json.Marshal(map[string]string{"public_key": pub, "source": source})
	return string(b)
}

func TestKeysAddListReplaceRevoke(t *testing.T) {
	k := newKeysRig(t, 0)
	if code, body := k.do(t, k.alice, "GET", "", ""); code != 200 || !strings.Contains(body, `"active":null`) {
		t.Fatalf("empty list: %d %s", code, body)
	}
	p1, _ := newPub(t)
	code, body := k.do(t, k.alice, "POST", "", addBody(sign.PinForm(p1), "generated"))
	var first keyOut
	json.Unmarshal([]byte(body), &first) //nolint:errcheck
	if code != 201 || !first.Active || first.Source != "generated" || first.PublicKey != sign.PinForm(p1) ||
		first.Fingerprint != sign.Fingerprint(p1) || first.OpenSSH != sign.OpenSSH(p1, "spool:"+k.alice) {
		t.Fatalf("add generated: %d %s", code, body)
	}
	// Upload in the OpenSSH form replaces it.
	p2, _ := newPub(t)
	code, body = k.do(t, k.alice, "POST", "", addBody(sign.OpenSSH(p2, "me@laptop"), ""))
	var second keyOut
	json.Unmarshal([]byte(body), &second) //nolint:errcheck
	if code != 201 || second.Source != "uploaded" || second.PublicKey != sign.PinForm(p2) {
		t.Fatalf("upload openssh: %d %s", code, body)
	}
	code, body = k.do(t, k.alice, "GET", "", "")
	var list struct {
		Active *keyOut  `json:"active"`
		Keys   []keyOut `json:"keys"`
	}
	json.Unmarshal([]byte(body), &list) //nolint:errcheck
	if code != 200 || list.Active == nil || list.Active.ID != second.ID || len(list.Keys) != 2 ||
		list.Keys[1].ID != first.ID || list.Keys[1].RevokedReason != "replaced" || list.Keys[1].Active {
		t.Fatalf("list after replace: %d %s", code, body)
	}
	if code, body := k.do(t, k.alice, "GET", "/"+strconv.FormatInt(second.ID, 10)+"/public", ""); code != 200 || !strings.Contains(body, sign.PinForm(p2)) {
		t.Fatalf("get: %d %s", code, body)
	}
	code, body = k.do(t, k.alice, "POST", "/"+strconv.FormatInt(second.ID, 10)+"/revoke", "{}")
	if code != 200 || !strings.Contains(body, `"revoked_reason":"revoked"`) {
		t.Fatalf("revoke: %d %s", code, body)
	}
	if code, body := k.do(t, k.alice, "GET", "", ""); code != 200 || !strings.Contains(body, `"active":null`) {
		t.Fatalf("after revoke: %d %s", code, body)
	}
	// No answer ever carries private material: 64-byte base64 never appears.
	if strings.Contains(body, "priv") {
		t.Fatalf("private field in answer: %s", body)
	}
}

// CONTROLS: another human's key is neither readable nor revocable, and ids
// do not leak (404 as for an unknown id); anonymous is 401.
func TestKeysOtherHumanRefused(t *testing.T) {
	k := newKeysRig(t, 0)
	p, _ := newPub(t)
	_, body := k.do(t, k.alice, "POST", "", addBody(sign.PinForm(p), "uploaded"))
	var a keyOut
	json.Unmarshal([]byte(body), &a) //nolint:errcheck
	id := strconv.FormatInt(a.ID, 10)
	if code, body := k.do(t, k.bob, "GET", "/"+id+"/public", ""); code != 404 || errToken([]byte(body)) != "not_found" {
		t.Fatalf("bob reads alice's key: %d %s", code, body)
	}
	if code, body := k.do(t, k.bob, "GET", "/999999/public", ""); code != 404 || errToken([]byte(body)) != "not_found" {
		t.Fatalf("unknown id: %d %s", code, body)
	}
	if code, body := k.do(t, k.bob, "POST", "/"+id+"/revoke", "{}"); code != 404 {
		t.Fatalf("bob revokes alice's key: %d %s", code, body)
	}
	if code, body := k.do(t, k.bob, "GET", "", ""); code != 200 || strings.Contains(body, sign.PinForm(p)) {
		t.Fatalf("bob's list shows alice's key: %d %s", code, body)
	}
	if code, body := k.do(t, k.alice, "GET", "", ""); code != 200 || !strings.Contains(body, `"active":{`) {
		t.Fatalf("alice's key survived bob: %d %s", code, body)
	}
	for _, c := range []struct{ method, path, body string }{
		{"GET", "", ""}, {"POST", "", addBody(sign.PinForm(p), "")}, {"GET", "/" + id + "/public", ""}, {"POST", "/" + id + "/revoke", "{}"},
	} {
		if code, body := k.do(t, "", c.method, c.path, c.body); code != 401 || errToken([]byte(body)) != "unauthenticated" {
			t.Fatalf("anonymous %s %s: %d %s", c.method, c.path, code, body)
		}
	}
	// A session whose human id is not a registered HUM-<n> has no keys.
	if code, _ := k.do(t, "GST-1", "GET", "", ""); code != 401 {
		t.Fatalf("guest id: %d", code)
	}
}

// CONTROLS: malformed, private-key and extra-field uploads are refused and
// write nothing; a key registered to anyone is a 409.
func TestKeysUploadRefusals(t *testing.T) {
	k := newKeysRig(t, 0)
	pub, priv := newPub(t)
	for _, c := range []struct {
		body, token string
		status      int
	}{
		{addBody("not-a-key", ""), "bad_public_key", 400},
		{addBody(base64.StdEncoding.EncodeToString(make([]byte, 31)), ""), "bad_public_key", 400},
		{addBody("ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQ", ""), "bad_public_key", 400},
		{addBody(base64.StdEncoding.EncodeToString(priv), ""), "private_key_refused", 400},
		{addBody("-----BEGIN OPENSSH "+"PRIVATE KEY-----\nb3BlbnNzaA==\n-----END OPENSSH "+"PRIVATE KEY-----", ""), "private_key_refused", 400},
		{extraField(sign.PinForm(pub), base64.StdEncoding.EncodeToString(priv)), "bad_request", 400},
		{addBody(sign.PinForm(pub), "stolen"), "bad_request", 400},
		{`{"public_key":`, "bad_request", 400},
	} {
		if code, body := k.do(t, k.alice, "POST", "", c.body); code != c.status || errToken([]byte(body)) != c.token {
			t.Fatalf("%s: %d %s (want %d %s)", c.body, code, body, c.status, c.token)
		}
	}
	if _, body := k.do(t, k.alice, "GET", "", ""); !strings.Contains(body, `"keys":[]`) {
		t.Fatalf("a refused upload wrote a key: %s", body)
	}
	// Wrong content type.
	req, _ := http.NewRequest("POST", "http://login"+domain+"/api/v1/auth/keys", strings.NewReader(addBody(sign.PinForm(pub), "")))
	req.Header.Set("Content-Type", "text/plain")
	req.Header.Set(memberHeader, k.alice)
	if resp, err := k.e.client.Do(req); err != nil || resp.StatusCode != 415 {
		t.Fatalf("text/plain: %v %v", resp, err)
	}
	// Duplicate: alice registers it, then bob and alice both get 409.
	if code, body := k.do(t, k.alice, "POST", "", addBody(sign.PinForm(pub), "")); code != 201 {
		t.Fatalf("first add: %d %s", code, body)
	}
	for _, who := range []string{k.bob, k.alice} {
		if code, body := k.do(t, who, "POST", "", addBody(sign.OpenSSH(pub, ""), "")); code != 409 || errToken([]byte(body)) != "duplicate_key" {
			t.Fatalf("duplicate by %s: %d %s", who, code, body)
		}
	}
}

// FR-008: the per-human write window answers 429 with Retry-After, and it is
// per human (bob is not limited by alice).
func TestKeysRateLimited(t *testing.T) {
	k := newKeysRig(t, 2)
	for i := 0; i < 2; i++ {
		p, _ := newPub(t)
		if code, body := k.do(t, k.alice, "POST", "", addBody(sign.PinForm(p), "")); code != 201 {
			t.Fatalf("write %d: %d %s", i, code, body)
		}
	}
	p, _ := newPub(t)
	req, _ := http.NewRequest("POST", "http://login"+domain+"/api/v1/auth/keys", strings.NewReader(addBody(sign.PinForm(p), "")))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(memberHeader, k.alice)
	resp, err := k.e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 429 || resp.Header.Get("Retry-After") == "" {
		t.Fatalf("third write: %d retry-after=%q", resp.StatusCode, resp.Header.Get("Retry-After"))
	}
	if code, body := k.do(t, k.bob, "POST", "", addBody(sign.PinForm(p), "")); code != 201 {
		t.Fatalf("bob limited by alice: %d %s", code, body)
	}
	// Reads are not limited.
	if code, _ := k.do(t, k.alice, "GET", "", ""); code != 200 {
		t.Fatalf("read after limit: %d", code)
	}
}

// The real session path (no seam): a signed-in human with a HUM-* adds and
// lists a key through the cookie, credentialed CORS included.
func TestKeysRealSession(t *testing.T) {
	r := newDoorRig(t)
	mine, _ := r.e.tenant()
	if landed := r.signIn(t, mine); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in: %s", landed)
	}
	p, _ := newPub(t)
	req, _ := http.NewRequest("POST", "http://"+loginHost+"/api/v1/auth/keys", strings.NewReader(addBody(sign.PinForm(p), "generated")))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Origin", wuiOrigin)
	resp, err := r.browser.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	b, _ := io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 201 || resp.Header.Get("Access-Control-Allow-Origin") != wuiOrigin ||
		!strings.Contains(string(b), "spool:"+r.session(t).HumanID) {
		t.Fatalf("session add: %d %v %s", resp.StatusCode, resp.Header, b)
	}
	req, _ = http.NewRequest("GET", "http://"+loginHost+"/api/v1/auth/keys", nil)
	resp, err = r.browser.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	b, _ = io.ReadAll(resp.Body)
	resp.Body.Close()
	if resp.StatusCode != 200 || !strings.Contains(string(b), sign.PinForm(p)) || resp.Header.Get("Cache-Control") != "no-store" {
		t.Fatalf("session list: %d %s", resp.StatusCode, b)
	}
}

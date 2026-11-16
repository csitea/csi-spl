package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// ---- pins over REST --------------------------------------------------------------

func TestPinRESTRootSigned(t *testing.T) {
	e := newEnv(t)
	tid, root := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	post := func(req wire.PinRequest) (int, []byte) {
		body, _ := jsonBody(req)
		resp, err := e.client.Post(e.url(tid)+"/v1/pins", "application/json", body)
		if err != nil {
			t.Fatal(err)
		}
		raw, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		return resp.StatusCode, raw
	}
	ts := time.Now().UTC().Format(time.RFC3339)
	p, _ := wire.PinPayload("box-a", a.pub, ts, false)
	code, raw := post(wire.PinRequest{BoxID: "box-a", PubKey: a.pub, TS: ts, Sig: sign.Sign(root, p)})
	if code != 200 {
		t.Fatalf("root-signed pin: %d %s", code, raw)
	}
	// Check field NAMES and the key bytes, not a substring of the body: a
	// random base64 pubkey can itself contain "priv" (run 36243397751).
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(raw, &fields); err != nil {
		t.Fatalf("pin response is not a JSON object: %v %s", err, raw)
	}
	for k := range fields {
		if k != "box_id" && k != "pubkey" {
			t.Fatalf("pin response has an unexpected field %q: %s", k, raw)
		}
	}
	if aPriv, err := sign.LoadPrivate(a.cfg.KeysDir, "box-a"); err != nil {
		t.Fatal(err)
	} else if strings.Contains(string(raw), base64.StdEncoding.EncodeToString(aPriv)) {
		t.Fatalf("pin response leaked the box private key: %s", raw)
	}
	code, _ = post(wire.PinRequest{BoxID: "box-a", PubKey: a.pub, TS: ts, Sig: sign.Sign(root, p)})
	if code != 200 {
		t.Fatalf("idempotent same-key pin: %d", code)
	}
	_, other, _ := ed25519.GenerateKey(nil)
	if code, _ = post(wire.PinRequest{BoxID: "box-a", PubKey: a.pub, TS: ts, Sig: sign.Sign(other, p)}); code != 400 {
		t.Fatalf("non-root pin: %d", code)
	}
	k2, _, _ := ed25519.GenerateKey(nil)
	k2s := base64.StdEncoding.EncodeToString(k2)
	p2, _ := wire.PinPayload("box-a", k2s, ts, false)
	if code, _ = post(wire.PinRequest{BoxID: "box-a", PubKey: k2s, TS: ts, Sig: sign.Sign(root, p2)}); code != 409 {
		t.Fatalf("different key without force: %d", code)
	}
	pb, _ := wire.PinPayload("box-b", b.pub, ts, false)
	if code, _ = post(wire.PinRequest{BoxID: "box-b", PubKey: b.pub, TS: ts, Sig: sign.Sign(root, pb)}); code != 200 {
		t.Fatalf("second box pin: %d", code)
	}

	// GET /v1/pins needs the WS upload token (003 http-v1.md); anonymous is 401.
	resp, err := e.client.Get(e.url(tid) + "/v1/pins")
	if err != nil || resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("anonymous GET /v1/pins: %v %v", err, resp)
	}
	resp.Body.Close()
	if _, err := a.c.Sync(context.Background()); err != nil {
		t.Fatalf("pinned box sync: %v", err)
	}
	c, n := e.raw(tid)
	hello := helloFrame(a, n, ts, wire.RoleCLI)
	wsjson.Write(context.Background(), c, hello) //nolint:errcheck
	var wel wire.Frame
	if err := wsjson.Read(context.Background(), c, &wel); err != nil || wel.UploadToken == "" {
		t.Fatalf("welcome token: %v %+v", err, wel)
	}
	c.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
	req, _ := http.NewRequest(http.MethodGet, e.url(tid)+"/v1/pins", nil)
	req.Header.Set("Authorization", "Bearer "+wel.UploadToken)
	resp, err = e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("GET /v1/pins: %d", resp.StatusCode)
	}
	var list wire.PinList
	if err := json.NewDecoder(resp.Body).Decode(&list); err != nil {
		t.Fatal(err)
	}
	if len(list.Pins) != 2 || list.Pins[0].BoxID != "box-a" || list.Pins[1].BoxID != "box-b" {
		t.Fatalf("GET list = %+v", list.Pins)
	}
	if list.Pins[0].PubKey != a.pub || list.Pins[1].PubKey != b.pub {
		t.Fatalf("GET pubkeys drifted: %+v", list.Pins)
	}
}

func TestPinRevokeAndForce(t *testing.T) {
	e := newEnv(t)
	tid, root := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	// Each pin op signs a later ts (004 pin-semantics §5); hello uses ts.
	ts := time.Now().UTC().Format(time.RFC3339)
	tsAt := func(d time.Duration) string { return time.Now().Add(d).UTC().Format(time.RFC3339Nano) }
	tsPin, tsRevoke, tsForce := tsAt(-30*time.Second), tsAt(-20*time.Second), tsAt(-10*time.Second)
	p, _ := wire.PinPayload("box-a", a.pub, tsPin, false)
	body, _ := jsonBody(wire.PinRequest{BoxID: "box-a", PubKey: a.pub, TS: tsPin, Sig: sign.Sign(root, p)})
	resp, _ := e.client.Post(e.url(tid)+"/v1/pins", "application/json", body)
	if resp.StatusCode != 200 {
		t.Fatalf("pin: %d", resp.StatusCode)
	}
	resp.Body.Close()

	ctx := context.Background()
	sess, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}

	rp, _ := wire.RevokePayload("box-a", tsRevoke)
	rbody, _ := jsonBody(wire.RevokeRequest{BoxID: "box-a", TS: tsRevoke, Sig: sign.Sign(root, rp)})
	req, _ := http.NewRequest(http.MethodDelete, e.url(tid)+"/v1/pins/box-a", rbody)
	req.Header.Set("Content-Type", "application/json")
	resp, err = e.client.Do(req)
	if err != nil || resp.StatusCode != 200 {
		t.Fatalf("revoke: %v %v", err, resp)
	}
	resp.Body.Close()
	select {
	case <-sess.Done():
		if sess.CloseCode() != wire.CloseUnauthorized {
			t.Fatalf("revoked session close %d, want 4401", sess.CloseCode())
		}
	case <-time.After(3 * time.Second):
		t.Fatal("revoked box session was not closed")
	}
	if _, err := e.st.GetPin(ctx, tid, "box-a"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("revoked pin still active: %v", err)
	}

	c, n := e.raw(tid)
	wsjson.Write(ctx, c, helloFrame(a, n, ts, wire.RoleCLI)) //nolint:errcheck
	if code, why := closeReason(t, c); code != wire.CloseUnauthorized || why != "unpinned_box" {
		t.Fatalf("hello after revoke: %d %q", code, why)
	}

	k2, priv2, _ := ed25519.GenerateKey(nil)
	k2s := base64.StdEncoding.EncodeToString(k2)
	p2, _ := wire.PinPayload("box-a", k2s, tsForce, false)
	body, _ = jsonBody(wire.PinRequest{BoxID: "box-a", PubKey: k2s, TS: tsForce, Sig: sign.Sign(root, p2)})
	resp, _ = e.client.Post(e.url(tid)+"/v1/pins", "application/json", body)
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("new key without force after revoke: %d", resp.StatusCode)
	}
	resp.Body.Close()
	// The old key on the revoked pin, even signed fresh, needs force.
	pOld, _ := wire.PinPayload("box-a", a.pub, tsForce, false)
	body, _ = jsonBody(wire.PinRequest{BoxID: "box-a", PubKey: a.pub, TS: tsForce, Sig: sign.Sign(root, pOld)})
	resp, _ = e.client.Post(e.url(tid)+"/v1/pins", "application/json", body)
	if resp.StatusCode != http.StatusConflict {
		t.Fatalf("same key on a revoked pin without force: %d", resp.StatusCode)
	}
	resp.Body.Close()
	p3, _ := wire.PinPayload("box-a", k2s, tsForce, true)
	body, _ = jsonBody(wire.PinRequest{BoxID: "box-a", PubKey: k2s, TS: tsForce, Force: true, Sig: sign.Sign(root, p3)})
	resp, _ = e.client.Post(e.url(tid)+"/v1/pins", "application/json", body)
	if resp.StatusCode != 200 {
		t.Fatalf("force new key: %d", resp.StatusCode)
	}
	resp.Body.Close()

	// A captured revoke replayed after the force re-pin is refused, and the
	// new key stays active.
	rbody, _ = jsonBody(wire.RevokeRequest{BoxID: "box-a", TS: tsRevoke, Sig: sign.Sign(root, rp)})
	req, _ = http.NewRequest(http.MethodDelete, e.url(tid)+"/v1/pins/box-a", rbody)
	req.Header.Set("Content-Type", "application/json")
	resp, err = e.client.Do(req)
	if err != nil {
		t.Fatal(err)
	}
	var eb wire.ErrorBody
	json.NewDecoder(resp.Body).Decode(&eb) //nolint:errcheck
	resp.Body.Close()
	if resp.StatusCode != http.StatusConflict || eb.Error != "stale_pin_op" {
		t.Fatalf("replayed revoke: %d %q", resp.StatusCode, eb.Error)
	}
	if got, err := e.st.GetPin(ctx, tid, "box-a"); err != nil || base64.StdEncoding.EncodeToString(got) != k2s {
		t.Fatalf("replayed revoke changed the pin: %v", err)
	}

	// Operator --force: new private key AND local pin. Sidecar will not clobber
	// a local pin that still holds the revoked key (004 T008).
	os.WriteFile(filepath.Join(a.cfg.KeysDir, "box-box-a.key"), []byte(base64.StdEncoding.EncodeToString(priv2)+"\n"), 0o600) //nolint:errcheck
	if err := sign.Pin(a.cfg.PinsDir, "box-a", k2s, true); err != nil {
		t.Fatal(err)
	}
	a.pub = k2s
	if _, err := a.c.Sync(ctx); err != nil {
		t.Fatalf("hello with forced key: %v", err)
	}
}

func TestPinCLIPublishesAndHygiene(t *testing.T) {
	e := newEnv(t)
	tid, root := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b")
	rootPath := filepath.Join(t.TempDir(), "root.key")
	if err := os.WriteFile(rootPath, []byte(base64.StdEncoding.EncodeToString(root)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	if err := action.Pin(a.cfg, action.PinArgs{Box: "box-a", PubKey: a.pub, RootKey: rootPath, HTTP: e.client}); err != nil {
		t.Fatalf("spool-pin publish: %v", err)
	}
	if _, err := sign.LoadPin(a.cfg.PinsDir, "box-a"); err != nil {
		t.Fatalf("local pin missing after publish: %v", err)
	}
	if err := action.Pin(a.cfg, action.PinArgs{Box: "box-b", PubKey: b.pub, RootKey: rootPath, HTTP: e.client}); err != nil {
		t.Fatalf("second box: %v", err)
	}
	_, err := action.PublishPin(a.cfg, action.PinArgs{Box: "box-a", PubKey: b.pub, RootKey: rootPath, HTTP: e.client})
	if action.ExitCode(err) != 78 {
		t.Fatalf("collision without force: %v (exit %d)", err, action.ExitCode(err))
	}
	if err := action.Pin(a.cfg, action.PinArgs{Box: "box-a", Revoke: true, RootKey: rootPath, HTTP: e.client}); err != nil {
		t.Fatalf("spool-pin --revoke: %v", err)
	}
	if _, err := e.st.GetPin(context.Background(), tid, "box-a"); !errors.Is(err, store.ErrNotFound) {
		t.Fatalf("hub pin survived revoke: %v", err)
	}

	req, _ := json.Marshal(wire.PinRequest{BoxID: "box-a", PubKey: a.pub, TS: "2026-09-18T12:00:00Z", Sig: "sig"})
	var obj map[string]any
	if err := json.Unmarshal(req, &obj); err != nil {
		t.Fatal(err)
	}
	for k := range obj {
		lk := strings.ToLower(k)
		if strings.Contains(lk, "priv") || lk == "seed" || lk == "key" {
			t.Fatalf("pin JSON field %q looks like a private key", k)
		}
	}
	for _, path := range []string{"/v1/pins/task", "/v1/pins/kind/note"} {
		resp, err := e.client.Get(e.url(tid) + path)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound && resp.StatusCode != http.StatusMethodNotAllowed {
			t.Fatalf("per-kind route %s: %d", path, resp.StatusCode)
		}
		resp, err = e.client.Post(e.url(tid)+path, "application/json", strings.NewReader(`{}`))
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNotFound && resp.StatusCode != http.StatusMethodNotAllowed {
			t.Fatalf("per-kind POST %s: %d", path, resp.StatusCode)
		}
	}
}

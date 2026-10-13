package hub_test

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/json"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 136 L6a (SPL-1670) section 8.1: a seat learns its workspace's
// spool_enc flag at pin time (the POST /v1/pins answer) and from the roster
// (the welcome and roster frames). A plain workspace's answers carry no
// spool_enc key at all, so they stay byte for byte what they were (rule 1).
// Memory, and Postgres with SPOOL_TEST_PG_DSN.

// pinAnswer is the raw POST /v1/pins answer for a fresh key of boxID.
func (e *env) pinAnswer(tenant string, root ed25519.PrivateKey, boxID string) (int, string) {
	e.t.Helper()
	pub := pubB64(newKey(e.t))
	ts := time.Now().UTC().Format(time.RFC3339)
	payload, _ := wire.PinPayload(boxID, pub, ts, false)
	body, _ := json.Marshal(wire.PinRequest{BoxID: boxID, PubKey: pub, TS: ts, Sig: sign.Sign(root, payload)})
	resp, err := e.client.Post(e.url(tenant)+"/v1/pins", "application/json", bytes.NewReader(body))
	if err != nil {
		e.t.Fatal(err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(raw)
}

// helloRaw seats agents on b over a raw box socket and returns the socket
// and the welcome frame's raw JSON.
func (e *env) helloRaw(tenant string, b *box, agents ...string) (*websocket.Conn, string) {
	e.t.Helper()
	c, n := e.raw(tenant)
	h := helloFrame(b, n, time.Now().UTC().Format(time.RFC3339), wire.RoleBox)
	h.Agents = agents
	wsjson.Write(context.Background(), c, h) //nolint:errcheck
	return c, nextOfType(e.t, c, wire.TWelcome)
}

// nextOfType reads raw frames until one of type typ, within 5 s.
func nextOfType(t *testing.T, c *websocket.Conn, typ string) string {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	for {
		_, raw, err := c.Read(ctx)
		if err != nil {
			t.Fatalf("no %s frame: %v", typ, err)
		}
		var f wire.Frame
		if json.Unmarshal(raw, &f) == nil && f.Type == typ {
			return string(raw)
		}
	}
}

func TestSpoolEncFlagReachesSeat(t *testing.T) {
	e := newEnv(t)
	ctx := context.Background()
	plain, plainRoot := e.tenant()
	enc, encRoot := e.tenant()
	if _, err := e.st.(store.TenantKV).SetTenantSettings(ctx, enc,
		store.TenantSettingsPatch{Set: map[string]any{"spool_enc": true}}); err != nil {
		t.Fatalf("flag on: %v", err)
	}
	const key = `"spool_enc"`

	// Pin time.
	if code, raw := e.pinAnswer(enc, encRoot, "box-e"); code != http.StatusOK || !strings.Contains(raw, key+":true") {
		t.Fatalf("enc pin answer: %d %s", code, raw)
	}
	if code, raw := e.pinAnswer(plain, plainRoot, "box-p"); code != http.StatusOK || strings.Contains(raw, key) {
		t.Fatalf("CONTROL plain pin answer: %d %s", code, raw)
	}

	// Welcome, then the roster frame a second box's hello pushes.
	for _, w := range []struct {
		tenant string
		want   bool
	}{{enc, true}, {plain, false}} {
		a, b := e.box(w.tenant, "box-a"), e.box(w.tenant, "box-b")
		e.pin(w.tenant, a)
		e.pin(w.tenant, b)
		ca, welcome := e.helloRaw(w.tenant, a, "c-101")
		cb, _ := e.helloRaw(w.tenant, b, "c-102")
		roster := nextOfType(t, ca, wire.TRoster)
		for what, raw := range map[string]string{"welcome": welcome, "roster": roster} {
			if got := strings.Contains(raw, key+":true"); got != w.want || (!w.want && strings.Contains(raw, key)) {
				t.Fatalf("%s frame, enc=%v: %s", what, w.want, raw)
			}
		}
		ca.CloseNow() //nolint:errcheck
		cb.CloseNow() //nolint:errcheck
	}
}

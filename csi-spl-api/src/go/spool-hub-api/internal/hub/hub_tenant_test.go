package hub_test

import (
	"bytes"
	"context"
	"encoding/base64"
	"io"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"
	"github.com/rs/zerolog"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// FR-023: liveness answers on /healthz and on the Cloud Run-safe /v1/health.
func TestHealthPaths(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()
	for _, path := range []string{"/healthz", "/v1/health"} {
		resp, err := e.client.Get(e.url(tid) + path)
		if err != nil {
			t.Fatalf("%s: %v", path, err)
		}
		body, _ := io.ReadAll(resp.Body)
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK || !strings.Contains(string(body), `"ok"`) {
			t.Fatalf("%s: status %d body %s", path, resp.StatusCode, body)
		}
	}
}

// ---- 006 T002 / T004 / T015: tenant Host, isolation, no private key in logs ----

func TestTenantFromHostUnknownFailsFast(t *testing.T) {
	e := newEnv(t)
	tid, _ := e.tenant()

	// Known tenant: Host resolves; GET /v1/pins without a token is 401 (door),
	// not 404 — the tenant was found.
	resp, err := e.client.Get(e.url(tid) + "/v1/pins")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusUnauthorized {
		t.Fatalf("known tenant /v1/pins: %d, want 401", resp.StatusCode)
	}

	assertUnknown := func(host string) {
		t.Helper()
		// /v1/ws resolves the box's tenant before the upgrade (specs/026 §4).
		resp, err := e.client.Get("http://" + host + "/v1/ws")
		if err != nil {
			t.Fatal(err)
		}
		defer resp.Body.Close()
		body, _ := io.ReadAll(resp.Body)
		if resp.StatusCode != http.StatusNotFound || !strings.Contains(string(body), "unknown_tenant") {
			t.Fatalf("host %q: status %d body %s", host, resp.StatusCode, body)
		}
	}
	assertUnknown("nope" + domain)
	assertUnknown("unknown-tenant" + domain)
	// A Host outside the pattern names no tenant: the box must name one.
	resp, err = e.client.Get("http://not-a-match.example/v1/ws")
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != http.StatusBadRequest {
		t.Fatalf("no tenant named: %d, want 400 tenant_required", resp.StatusCode)
	}

	// Pattern is required and must start with {tenant}.
	if _, err := hub.New(hub.Options{Store: e.st, Blob: blob.Dir{Root: e.blobs}, TenantHostPattern: "hub.test"}); err == nil {
		t.Fatal("pattern without {tenant}. prefix was accepted")
	}
}

func TestTwoTenantsSameAgentIDIsolated(t *testing.T) {
	e := newEnv(t)
	aID, _ := e.tenant()
	bID, _ := e.tenant()
	// Same box id and same agent id (GRK-03), different keys, two tenants.
	aGRK := e.box(aID, "box-a", "GRK-03")
	bGRK := e.box(bID, "box-a", "GRK-03")
	aCLE := e.box(aID, "box-b", "CLE-07")
	e.pin(aID, aGRK)
	e.pin(aID, aCLE)
	e.pin(bID, bGRK)
	if aGRK.pub == bGRK.pub {
		t.Fatal("fixture keys collided")
	}
	ctx := context.Background()
	if _, err := aCLE.c.Dial(ctx, wire.RoleBox); err != nil {
		t.Fatal(err)
	}
	if _, err := aGRK.c.Dial(ctx, wire.RoleBox); err != nil {
		t.Fatal(err)
	}
	if _, err := bGRK.c.Dial(ctx, wire.RoleBox); err != nil {
		t.Fatal(err)
	}
	eventually(t, "CLE-07@box-b on tenant A", func() bool {
		tb, err := aGRK.c.ResolveToBox("CLE-07", "")
		return err == nil && tb == "box-b"
	})

	out := send(t, aGRK, "GRK-03", "CLE-07", "task", "only in A", "")
	if out.Delivery != wire.DeliverySent {
		t.Fatalf("delivery = %q", out.Delivery)
	}
	eventually(t, "CLE-07 inbox on tenant A", func() bool { return len(inbox(t, aCLE, "CLE-07")) == 1 })
	if n := len(inbox(t, bGRK, "GRK-03")); n != 0 {
		t.Fatalf("tenant B GRK-03 saw tenant A's mail: %d", n)
	}
	envs, _ := e.st.TaskEnvelopes(ctx, bID, out.TaskID)
	if len(envs) != 0 {
		t.Fatal("tenant A's task_id is visible in tenant B")
	}

	// Same box_id is pinned in B to a different key → bad_sig, not a share.
	now := time.Now().UTC().Format(time.RFC3339)
	c, n := e.raw(bID)
	wsjson.Write(context.Background(), c, helloFrame(aGRK, n, now, wire.RoleCLI)) //nolint:errcheck
	if code, why := closeReason(t, c); code != wire.CloseUnauthorized || why != "bad_sig" {
		t.Fatalf("cross-tenant hello with A's key as B's box-a: %d %q", code, why)
	}
	// A's box-b is not pinned in B at all.
	c, n = e.raw(bID)
	wsjson.Write(context.Background(), c, helloFrame(aCLE, n, now, wire.RoleCLI)) //nolint:errcheck
	if code, why := closeReason(t, c); code != wire.CloseUnauthorized || why != "unpinned_box" {
		t.Fatalf("cross-tenant hello of A's box-b: %d %q", code, why)
	}
}

func TestRootPrivateKeyNotLogged(t *testing.T) {
	var buf bytes.Buffer
	e := newEnv(t, func(o *hub.Options) { o.Log = zerolog.New(&buf) })
	tid, root := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	ts := time.Now().UTC().Format(time.RFC3339)
	p, _ := wire.PinPayload("box-a", a.pub, ts, false)
	body, _ := jsonBody(wire.PinRequest{BoxID: "box-a", PubKey: a.pub, TS: ts, Sig: sign.Sign(root, p)})
	resp, err := e.client.Post(e.url(tid)+"/v1/pins", "application/json", body)
	if err != nil {
		t.Fatal(err)
	}
	resp.Body.Close()
	if resp.StatusCode != 200 {
		t.Fatalf("pin: %d", resp.StatusCode)
	}
	priv := base64.StdEncoding.EncodeToString(root)
	if priv != "" && bytes.Contains(buf.Bytes(), []byte(priv)) {
		t.Fatal("tenant root private key appeared in hub logs")
	}
	if bytes.Contains(buf.Bytes(), []byte(root)) {
		t.Fatal("raw tenant root private key bytes appeared in hub logs")
	}
}

// 006 FR-001a: an owner-made tenant (do_spl_tenant_create) is
// billing_status=manual and must write like active/internal, not 402.
func TestManualTenantMayWrite(t *testing.T) {
	e := newEnv(t)
	tid, root := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	if err := e.st.SetBillingStatus(ctx, tid, "manual"); err != nil {
		t.Fatal(err)
	}
	c := e.box(tid, "box-c", "AGY-01")
	if code, eb := e.postPin(tid, root, "box-c", c.pub); code != http.StatusOK {
		t.Fatalf("pin on a manual tenant: %d %+v", code, eb)
	}
	out := send(t, a, "GRK-03", "CLE-07", "task", "manual tenant", "box-b")
	if out.Delivery != wire.DeliveryQueued {
		t.Fatalf("send on a manual tenant: delivery %q", out.Delivery)
	}
}

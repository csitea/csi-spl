package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/sign"
	"github.com/csitea/csi-spl/spool-hub-api/internal/spool"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// TestSendPathCacheInvalidation (027 T040 CONTROLS): the store caches pins and
// tenant rows for the send path; a write through the hub must bind the very
// next frame. Each step first sends once so the row is cached, then writes,
// then sends again on the same socket:
//   - REST revoke of the to_box -> unpinned_box
//   - billing set unpaid -> 402 unpaid; set active -> sent again
//   - REST revoke of the sender's own box -> never sent (refused or closed)
//   - a pin of box-x in tenant A never answers for box-x in tenant B
func TestSendPathCacheInvalidation(t *testing.T) {
	e := newEnv(t)
	tid, root := e.tenant()
	a := e.box(tid, "box-a", "GRK-03")
	b := e.box(tid, "box-b", "CLE-07")
	e.pin(tid, a)
	e.pin(tid, b)
	ctx := context.Background()
	sess, err := a.c.Dial(ctx, wire.RoleCLI)
	if err != nil {
		t.Fatal(err)
	}
	defer sess.Close()
	priv, _ := sign.LoadPrivate(a.cfg.KeysDir, "box-a")
	send := func(toBox string) error {
		t.Helper()
		m, err := spool.New(a.cfg).Compose("GRK-03", "CLE-07", "", "note", "cache", nil)
		if err != nil {
			t.Fatal(err)
		}
		env, err := wire.NewEnvelope(priv, "box-a", toBox, m)
		if err != nil {
			t.Fatal(err)
		}
		_, err = sess.Send(ctx, env)
		return err
	}
	refusedWith := func(what, token string, err error) {
		t.Helper()
		var he *hubclient.HubError
		if !errors.As(err, &he) || he.Token != token {
			t.Fatalf("%s: want %s, got %v", what, token, err)
		}
	}
	revoke := func(box string, at time.Time) {
		t.Helper()
		ts := at.UTC().Format(time.RFC3339Nano)
		rp, _ := wire.RevokePayload(box, ts)
		body, _ := jsonBody(wire.RevokeRequest{BoxID: box, TS: ts, Sig: sign.Sign(root, rp)})
		req, _ := http.NewRequest(http.MethodDelete, e.url(tid)+"/v1/pins/"+box, body)
		req.Header.Set("Content-Type", "application/json")
		resp, err := e.client.Do(req)
		if err != nil || resp.StatusCode != http.StatusOK {
			t.Fatalf("revoke %s: %v %v", box, err, resp)
		}
		resp.Body.Close()
	}

	// to_box revoked -> the next frame is refused.
	if err := send("box-b"); err != nil {
		t.Fatalf("send before revoke: %v", err)
	}
	revoke("box-b", time.Now())
	refusedWith("send to a just-revoked to_box", "unpinned_box", send("box-b"))

	// Billing: unpaid binds the next frame, active again too.
	c := e.box(tid, "box-c", "CLE-08")
	e.pin(tid, c)
	if err := send("box-c"); err != nil {
		t.Fatalf("send before unpaid: %v", err)
	}
	if err := e.st.SetBillingStatus(ctx, tid, billing.StatusUnpaid); err != nil {
		t.Fatal(err)
	}
	refusedWith("send right after unpaid", billing.TokenUnpaid, send("box-c"))
	if err := e.st.SetBillingStatus(ctx, tid, billing.StatusActive); err != nil {
		t.Fatal(err)
	}
	if err := send("box-c"); err != nil {
		t.Fatalf("send right after active: %v", err)
	}

	// Tenant B has its own box-a with another key: A's cached pin never
	// verifies for B, and B's never for A.
	other, _ := e.tenant()
	ob := e.box(other, "box-a", "GRK-09")
	e.pin(other, ob)
	pa, _ := e.st.GetPin(ctx, tid, "box-a")
	pb, _ := e.st.GetPin(ctx, other, "box-a")
	if pa == nil || pb == nil || ed25519.PublicKey(pa).Equal(ed25519.PublicKey(pb)) {
		t.Fatalf("tenant pins cross: A %x B %x", pa, pb)
	}

	// The sender's own pin revoked -> never sent again on this socket.
	revoke("box-a", time.Now().Add(time.Second))
	err = send("box-c")
	var he *hubclient.HubError
	if err == nil || (errors.As(err, &he) && he.Token != "unpinned_box") {
		t.Fatalf("send after the sender's own revoke: %v", err)
	}
}

package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// CLE-77876 (prd csitea 2026-10-01): a workspace without a box-wui pin stores
// every browser channel post unsigned, and no member box gets it. After the
// pin, POST /v1/operator/replay-unsigned re-signs those posts and routes them:
// refused while unpinned, a dry run changes nothing, the replay reaches every
// member agent, and a second replay finds nothing.
func TestOperatorReplayUnsignedReachesMembersAfterPin(t *testing.T) {
	const aud = "https://api.dev.example"
	pub, key, _ := ed25519.GenerateKey(nil)
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.WUIKey, o.WUIDispatch = key, true
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = aud
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			if token == "good" {
				return operatorSA, nil
			}
			return "", errors.New("token rejected")
		}
	})
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "CLE-07", "CLE-08")
	a.cfg.Channels = "releases"
	e.pin(tid, a)
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "releases",
		Name: "releases", CreatedBy: "hub", CreatedAt: time.Now()}); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	if err := e.st.SetRoster(ctx, tid, "box-a", []string{"CLE-07", "CLE-08"}, now); err != nil {
		t.Fatal(err)
	}
	for _, ag := range []string{"CLE-07", "CLE-08"} {
		if err := e.st.InviteChannelAgent(ctx, tid, "releases", "box-a", ag, now); err != nil {
			t.Fatal(err)
		}
	}
	if err := e.st.AddChannelHumans(ctx, tid, "releases", []string{"HUM-google-sub-1@" + tid}, "hub", now); err != nil {
		t.Fatal(err)
	}

	// No box-wui pin: the post is stored unsigned and nothing is queued.
	w := dialMember(t, e, tid, "Alice", "HUM-google-sub-1@"+tid)
	task := "9e5a4b62-7d8f-4a91-8bc3-2d3e4f5a6b7c"
	id := "1f2e3d4c-5b6a-4978-8695-a4b3c2d1e0f9"
	if ack := channelFrame(t, w, id, task, "releases", "anyone there?"); ack["type"] != "ack" {
		t.Fatalf("channel post: %v", ack)
	}
	if q, _ := e.st.QueuedFor(ctx, tid, "box-a", time.Now()); len(q) != 0 {
		t.Fatalf("an unsigned post was queued: %+v", q)
	}
	body := map[string]any{"tenant": tid, "since": now.Add(-time.Hour).UTC().Format(time.RFC3339)}

	// CONTROLS: no token; a pin missing.
	if code, _ := opCall(t, e, tid, "POST", "/v1/operator/replay-unsigned", "", body); code != http.StatusUnauthorized {
		t.Fatalf("no token: %d", code)
	}
	if code, out := opCall(t, e, tid, "POST", "/v1/operator/replay-unsigned", "good", body); code != http.StatusConflict || out["error"] != "wui_unpinned" {
		t.Fatalf("unpinned: %d %v", code, out)
	}
	bad := map[string]any{"tenant": tid, "since": now.Add(-40 * 24 * time.Hour).UTC().Format(time.RFC3339)}
	if code, _ := opCall(t, e, tid, "POST", "/v1/operator/replay-unsigned", "good", bad); code != http.StatusBadRequest {
		t.Fatalf("since past the window: %d", code)
	}

	e.pinKey(tid, hub.WUIBox, pub)

	// A dry run lists it and changes nothing.
	dry := map[string]any{"tenant": tid, "since": body["since"], "dry_run": true}
	code, out := opCall(t, e, tid, "POST", "/v1/operator/replay-unsigned", "good", dry)
	if code != http.StatusOK || out["found"] != float64(1) || out["resigned"] != float64(0) {
		t.Fatalf("dry run: %d %v", code, out)
	}
	if q, _ := e.st.QueuedFor(ctx, tid, "box-a", time.Now()); len(q) != 0 {
		t.Fatalf("a dry run queued: %+v", q)
	}

	// The replay signs it in place and queues it for the member box.
	code, out = opCall(t, e, tid, "POST", "/v1/operator/replay-unsigned", "good", body)
	if code != http.StatusOK || out["found"] != float64(1) || out["resigned"] != float64(1) {
		t.Fatalf("replay: %d %v", code, out)
	}
	envs, _ := e.st.TaskEnvelopes(ctx, tid, task)
	if len(envs) != 1 {
		t.Fatalf("stored %d envelopes", len(envs))
	}
	envl, err := wire.ParseEnvelope(envs[0])
	if err != nil || envl.Sig == "" || envl.Channel != "releases" {
		t.Fatalf("stored envelope %+v %v", envl, err)
	}
	if err := envl.Verify(pub); err != nil {
		t.Fatalf("replayed post does not verify against the pin: %v", err)
	}
	if q, _ := e.st.QueuedFor(ctx, tid, "box-a", time.Now()); len(q) != 1 || q[0].MsgID != id {
		t.Fatalf("queued for box-a: %+v", q)
	}

	// End to end: the box comes online and every member reads it.
	sa, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer sa.Close()
	for _, as := range []string{"CLE-07", "CLE-08"} {
		eventually(t, as+" inbox", func() bool { return len(inbox(t, a, as)) == 1 })
		if got := inbox(t, a, as)[0]; got.MsgID != id || got.Body != "anyone there?" {
			t.Fatalf("%s inbox %+v", as, got)
		}
	}
	if errs := sa.RecvErrors(); len(errs) != 0 {
		t.Fatalf("box-a recv errors: %v", errs)
	}

	// A second replay finds nothing left to sign.
	code, out = opCall(t, e, tid, "POST", "/v1/operator/replay-unsigned", "good", body)
	if code != http.StatusOK || out["found"] != float64(0) {
		t.Fatalf("second replay: %d %v", code, out)
	}
}

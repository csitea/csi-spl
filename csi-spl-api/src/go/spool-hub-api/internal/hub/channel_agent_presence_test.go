package hub_test

import (
	"context"
	"errors"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-3717 (lessons-learnt row 8): Channel Properties > People said "box
// offline" while that box's agents answered. GET /v1/channels/{ch}/members
// read online as "THIS instance holds the box's socket", the rule the roster
// left behind in presence.go (t1 b3bf3d13): any other Cloud Run instance, or
// the next revision of a roll, called a connected box offline. It now reads
// the shared presence stamp, as the roster does.
func TestChannelAgentOnlineAcrossInstances(t *testing.T) {
	session := func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
	}
	e := newEnv(t, session)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "CLE-35")
	e.pin(tid, a)
	var skew atomic.Int64
	peer := newPeer(t, e, session, func(o *hub.Options) {
		o.Now = func() time.Time { return time.Now().Add(time.Duration(skew.Load())) }
	})
	human := "HUM-google-sub-1@" + tid
	now := time.Now()
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "mobile",
		Name: "mobile", CreatedBy: human, CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, "mobile", []string{human}, human, now); err != nil {
		t.Fatal(err)
	}
	if err := e.st.InviteChannelAgent(ctx, tid, "mobile", "box-a", "CLE-35", now); err != nil {
		t.Fatal(err)
	}
	if got := agentState(t, peer, tid, "mobile", human); got != "CLE-35@box-a seated" {
		t.Fatalf("never connected: %q", got)
	}

	connectBox(t, e, tid, a, "CLE-35")
	if got := agentState(t, e, tid, "mobile", human); got != "CLE-35@box-a online seated" {
		t.Fatalf("instance A (holds the socket): %q", got)
	}
	if got := agentState(t, peer, tid, "mobile", human); got != "CLE-35@box-a online seated" {
		t.Fatalf("box-a connected to instance A reads %q from instance B, want online", got)
	}

	// Silent past the TTL: offline on B as well, as the roster reads it.
	skew.Store(int64(61 * time.Second))
	if got := agentState(t, peer, tid, "mobile", human); got != "CLE-35@box-a seated" {
		t.Fatalf("box-a silent past the TTL on B: %q", got)
	}
}

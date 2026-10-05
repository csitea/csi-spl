package hub_test

// Perf edition 20261004 E13: one browser send into a members-only channel
// reads the channel's human members ONCE. The post door (wuiMayPost) and the
// live fan-out (fanoutWUI) each read channel_humans; the frame's request memo
// (wuiFrame) now serves the second. The Postgres side of the same pin is the
// "WS wui send (#perf-room)" row of TestRoundTripsPerRequest.

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

func TestWUISendReadsChannelHumansOnce(t *testing.T) {
	var cnt *humansCount
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.Authorizer = rbac.Fixed(rbac.Developer)
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
		cnt = &humansCount{Store: o.Store}
		o.Store = cnt
	})
	tid, _ := e.tenant()
	ctx, now := context.Background(), time.Now().UTC()
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "room", Name: "room", CreatedBy: "HUM-2", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, "room", []string{"HUM-2", "HUM-3"}, "HUM-2", now); err != nil {
		t.Fatal(err)
	}
	sender := dialMember(t, e, tid, "HUM-2", "HUM-2")
	reader := dialMember(t, e, tid, "HUM-3", "HUM-3")
	wsjson.Write(ctx, reader, map[string]string{"type": "subscribe", "channel": "room"}) //nolint:errcheck
	if f := readType(t, reader, "subscribed"); f["type"] != "subscribed" {
		t.Fatalf("subscribe: %v", f)
	}
	for i := 0; i < 3; i++ {
		before := cnt.n.Load()
		task := uuidV4()
		if ack := channelFrame(t, sender, uuidV4(), task, "room", "hello"); ack["type"] != "ack" {
			t.Fatalf("send %d: %v", i, ack)
		}
		if f := readType(t, reader, "message"); f["task_id"] != task {
			t.Fatalf("send %d: the member's live frame: %v", i, f)
		}
		if got := cnt.n.Load() - before; got != 1 {
			t.Fatalf("send %d read channel_humans %d times, want 1 (the post door and the fan-out share one read)", i, got)
		}
	}
	// The memo is the frame's, not the socket's: a member removed between two
	// frames is refused on the next one.
	if err := e.st.RemoveChannelHuman(ctx, tid, "room", "HUM-2"); err != nil {
		t.Fatal(err)
	}
	if f := channelFrame(t, sender, uuidV4(), uuidV4(), "room", "after"); f["type"] != "error" || f["error"] != "unknown_channel" {
		t.Fatalf("a removed member still posts on an open socket: %v", f)
	}
}

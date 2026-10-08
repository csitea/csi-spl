package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-950: a human's ALL-0 reply in a channel THREAD (is_parent 0, no channel
// tag - the WUI reply pane sends none) reaches every agent the channel's
// members invited, like the topic post above it. Measured on prd csi-rel
// 2026-09-26: such replies had one deliveries row, box-wui, because the
// tenant had no box-wui pin; the unpinned tenant is the control here.
func TestWUIChannelThreadReplyReachesInvitedAgents(t *testing.T) {
	for _, c := range []struct {
		name   string
		pinned bool
	}{{"pinned", true}, {"unpinned control", false}} {
		t.Run(c.name, func(t *testing.T) {
			pub, key, _ := ed25519.GenerateKey(nil)
			e := dispatchEnv(t, true, key)
			tid, _ := e.tenant()
			ctx := context.Background()
			d := e.box(tid, "box-desk", "GRK-35", "AGY-34")
			e.pin(tid, d)
			if c.pinned {
				e.pinKey(tid, hub.WUIBox, pub)
			}
			human := "HUM-google-sub-1@" + tid
			now := time.Now()
			if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "development",
				Name: "development", CreatedBy: human, CreatedAt: now}); err != nil {
				t.Fatal(err)
			}
			if err := e.st.AddChannelHumans(ctx, tid, "development", []string{human}, human, now); err != nil {
				t.Fatal(err)
			}
			if err := e.st.SetRoster(ctx, tid, "box-desk", []string{"GRK-35", "AGY-34"}, now); err != nil {
				t.Fatal(err)
			}
			for _, ag := range []string{"GRK-35", "AGY-34"} {
				if err := e.st.InviteChannelAgent(ctx, tid, "development", "box-desk", ag, now); err != nil {
					t.Fatal(err)
				}
			}

			w := dialMember(t, e, tid, "Owner", human)
			task := "5a6b7c8d-9e0f-4a1b-8c2d-3e4f5a6b7c8d"
			topic := "6b7c8d9e-0f1a-4b2c-9d3e-4f5a6b7c8d9e"
			reply := "7c8d9e0f-1a2b-4c3d-8e4f-5a6b7c8d9e0f"
			threadFrame(t, w, topic, task, "development", 1, "the topic")
			threadFrame(t, w, reply, task, "", 0, "please answer in this thread")

			m, err := e.st.GetEditable(ctx, tid, reply, time.Now())
			if err != nil || m.Channel != "development" || m.ToID != hub.BroadcastID {
				t.Fatalf("stored reply %+v %v", m, err)
			}
			state, err := e.st.DeliveryState(ctx, tid, reply, "box-desk")
			if !c.pinned {
				if !errors.Is(err, store.ErrNotFound) {
					t.Fatalf("unpinned tenant: box-desk delivery %q %v, want none", state, err)
				}
				return
			}
			if err != nil {
				t.Fatalf("box-desk has no delivery for the thread reply: %v", err)
			}
			envs, _ := e.st.TaskEnvelopes(ctx, tid, task)
			var got *wire.Envelope
			for _, raw := range envs {
				if x, _ := wire.ParseEnvelope(raw); x != nil {
					if in, _ := x.Inner(); in != nil && in.MsgID == reply {
						got = x
					}
				}
			}
			if got == nil || got.Channel != "development" || got.Verify(pub) != nil {
				t.Fatalf("reply envelope not signed for the channel: %+v", got)
			}

			s, err := d.c.Dial(ctx, wire.RoleBox)
			if err != nil {
				t.Fatal(err)
			}
			defer closeWait(s)
			for _, ag := range []string{"GRK-35", "AGY-34"} {
				eventually(t, ag+" inbox", func() bool {
					for _, x := range inbox(t, d, ag) {
						if x.MsgID == reply {
							return true
						}
					}
					return false
				})
			}
			if errs := s.RecvErrors(); len(errs) != 0 {
				t.Fatalf("box-desk recv errors: %v", errs)
			}
		})
	}
}

// threadFrame sends one browser line at a level; channel "" = no tag.
func threadFrame(t *testing.T, c *websocket.Conn, id, task, channel string, isParent int, body string) {
	t.Helper()
	f := map[string]any{"type": "send", "msg_id": id, "task_id": task, "kind": "note",
		"body": body, "is_parent": isParent}
	if channel != "" {
		f["channel"] = channel
	}
	wsjson.Write(context.Background(), c, f) //nolint:errcheck
	if ack := readType(t, c, "ack"); ack["type"] != "ack" {
		t.Fatalf("send %s: %v", id, ack)
	}
}

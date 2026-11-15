package action

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// pinsHub is a fake hub for one-shot role=cli sessions that answers each
// lane frame with answer(frame).
func pinsHub(t *testing.T, answer func(wire.Frame) wire.Frame) *verbHub {
	t.Helper()
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := websocket.Accept(w, r, &websocket.AcceptOptions{InsecureSkipVerify: true})
		if err != nil {
			return
		}
		defer conn.CloseNow() //nolint:errcheck
		ctx := r.Context()
		var hello, f wire.Frame
		if wsjson.Write(ctx, conn, wire.Frame{Type: wire.TChallenge, Nonce: "nonce-nonce-nonce"}) != nil || wsjson.Read(ctx, conn, &hello) != nil {
			return
		}
		if wsjson.Write(ctx, conn, wire.Frame{Type: wire.TWelcome, BoxID: hello.BoxID, UploadToken: "tok",
			UploadTokenExpiresAt: time.Now().Add(time.Hour).UTC().Format(time.RFC3339)}) != nil {
			return
		}
		for wsjson.Read(ctx, conn, &f) == nil {
			if wsjson.Write(ctx, conn, answer(f)) != nil {
				return
			}
		}
	}))
	t.Cleanup(srv.Close)
	return &verbHub{url: srv.URL}
}

// TestChannelPins (spec 164 4.3, row B4): the verb sends channel_pins_get
// {channel} with the channel normalised, returns the hub's answer as is,
// and turns every failure into an error: no hub mode, a bad channel id
// (before dialling), a hub refusal, no hub at all, and an answer that is
// not the asked channel's pins object.
func TestChannelPins(t *testing.T) {
	var sent wire.Frame
	reply := `{"channel":"lobby","box_pins":[],"is_pinned":false}`
	h := pinsHub(t, func(f wire.Frame) wire.Frame {
		sent = f
		var in struct{ Channel string }
		json.Unmarshal(f.Lane, &in) //nolint:errcheck
		switch in.Channel {
		case "refused":
			return wire.Frame{Type: wire.TError, MsgID: f.MsgID, Error: "unknown_channel", Status: http.StatusNotFound}
		case "partial":
			return wire.Frame{Type: wire.TLane, MsgID: f.MsgID, Lane: json.RawMessage(`{"channel":"partial","box_pins":[]}`)}
		case "garbage":
			return wire.Frame{Type: wire.TLane, MsgID: f.MsgID, Lane: json.RawMessage(`[1]`)}
		}
		return wire.Frame{Type: wire.TLane, MsgID: f.MsgID, Lane: json.RawMessage(reply)}
	})
	cfg := hubCfg(t, h)
	raw, err := ChannelPins(context.Background(), cfg, ChannelPinsArgs{Channel: "general"})
	if err != nil || string(raw) != reply {
		t.Fatalf("general: %s %v, want %s", raw, err, reply)
	}
	if sent.Type != wire.TLane || sent.LaneOp != "channel_pins_get" || string(sent.Lane) != `{"channel":"lobby"}` {
		t.Fatalf("sent %+v, want channel_pins_get {channel: lobby}", sent)
	}

	gone := hubCfg(t, h)
	dead := httptest.NewServer(nil)
	dead.Close()
	gone.HubURL = dead.URL
	for _, c := range []struct {
		name    string
		channel string
		want    string
	}{
		{"no hub mode", "deploys", "need hub mode"},
		{"bad channel id", "No Such!", "must be a channel id"},
		{"refused", "refused", "unknown_channel"},
		{"no hub", "deploys", "hub unreachable"},
		{"answer without is_pinned", "partial", "not channel pins JSON"},
		{"answer not an object", "garbage", "not channel pins JSON"},
		{"answer for another channel", "deploys", "not channel pins JSON"},
	} {
		use := cfg
		switch c.name {
		case "no hub mode":
			use = testkit.NewConfig(t)
		case "no hub":
			use = gone
		}
		if raw, err := ChannelPins(context.Background(), use, ChannelPinsArgs{Channel: c.channel}); err == nil || raw != nil || !strings.Contains(err.Error(), c.want) {
			t.Errorf("%s: %s %v, want an error naming %q", c.name, raw, err, c.want)
		}
	}
}

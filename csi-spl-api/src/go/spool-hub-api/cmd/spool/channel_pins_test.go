package main

import (
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/testkit"
)

const channelPinsReply = `{"channel":"deploys","box_pins":["box-x"],"is_pinned":true}`

// TestChannelPinsCLI (spec 164 section 4.3, row B4): `spool channel-pins
// --channel <c>` sends channel_pins_get {channel} and prints the hub's answer
// as is, exit 0. The CONTROL: when the hub does not answer (nothing listens),
// refuses, or answers something else, it exits non-zero and prints nothing,
// so the placer (B5) never reads a failure as "unpinned".
func TestChannelPinsCLI(t *testing.T) {
	h := newScriptHub(t, laneAnswer(map[string]string{"channel_pins_get": channelPinsReply}), nil)
	rc, out, errOut := capture(t, "", func() int { return cmdChannelPins(hubCfg(t, h.URL), []string{"--channel", "deploys"}) })
	if rc != 0 || out != channelPinsReply+"\n" {
		t.Fatalf("channel-pins: rc %d %q err %q, want 0 %q", rc, out, errOut, channelPinsReply)
	}
	fr := h.Frames()
	if len(fr) != 1 || fr[0].LaneOp != "channel_pins_get" || string(fr[0].Lane) != `{"channel":"deploys"}` {
		t.Fatalf("frames = %d %+v, want one channel_pins_get {channel: deploys}", len(fr), fr)
	}

	gone := httptest.NewServer(nil)
	gone.Close() // CONTROL: the hub does not answer
	refuse := newScriptHub(t, laneAnswer(nil), nil)
	other := newScriptHub(t, laneAnswer(map[string]string{"channel_pins_get": `{"channel":"lobby","box_pins":[],"is_pinned":false}`}), nil)
	partial := newScriptHub(t, laneAnswer(map[string]string{"channel_pins_get": `{"channel":"deploys"}`}), nil)
	for _, c := range []struct {
		name string
		url  string
		args []string
		want string
	}{
		{"hub does not answer", gone.URL, []string{"--channel", "deploys"}, ""},
		{"hub refuses", refuse.URL, []string{"--channel", "deploys"}, "bad_lane_op"},
		{"answer for another channel", other.URL, []string{"--channel", "deploys"}, "not channel pins JSON"},
		{"answer without box_pins", partial.URL, []string{"--channel", "deploys"}, "not channel pins JSON"},
		{"local mode", "", []string{"--channel", "deploys"}, "need hub mode"},
		{"no channel", refuse.URL, nil, "usage: spool channel-pins"},
		{"extra argument", refuse.URL, []string{"--channel", "deploys", "x"}, "usage: spool channel-pins"},
		{"not a channel id", refuse.URL, []string{"--channel", "No Such!"}, "must be a channel id"},
	} {
		cfg := testkit.NewConfig(t)
		if c.url != "" {
			cfg = hubCfg(t, c.url)
		}
		rc, out, errOut := capture(t, "", func() int { return cmdChannelPins(cfg, c.args) })
		if rc == 0 || out != "" || !strings.Contains(errOut, c.want) {
			t.Errorf("%s: rc %d out %q err %q, want non-zero naming %q", c.name, rc, out, errOut, c.want)
		}
	}
	if n := len(refuse.Frames()); n != 1 {
		t.Errorf("refusing hub read %d frames, want 1 (usage errors are refused before dialling)", n)
	}
}

package hub_test

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// channelPinsOf is lane_op channel_pins_get through c (a one-shot role=cli
// session signed by the box's own key, as `spool channel-pins` sends it).
func channelPinsOf(t *testing.T, c *hubclient.Client, channel string) (string, []string, bool, error) {
	t.Helper()
	row, _ := json.Marshal(map[string]string{"channel": channel})
	raw, err := c.Lane(context.Background(), "channel_pins_get", "", row)
	if err != nil {
		return "", nil, false, err
	}
	var out struct {
		Channel  string    `json:"channel"`
		BoxPins  *[]string `json:"box_pins"`
		IsPinned *bool     `json:"is_pinned"`
	}
	if err := json.Unmarshal(raw, &out); err != nil || out.BoxPins == nil || out.IsPinned == nil {
		t.Fatalf("channel_pins_get answer %s: %v", raw, err)
	}
	return out.Channel, *out.BoxPins, *out.IsPinned, nil
}

// Spec 164 section 4.3, row B4: a box reads a channel's box pins with its own
// key, in its own workspace only. The CONTROL (spec 164 section 8): a box of
// workspace B never reads workspace A's pins, neither for a channel of the
// same name in B (B's own, unpinned) nor for a channel only A has
// (unknown_channel, not an unpinned answer).
func TestBoxChannelPins(t *testing.T) {
	e := newEnv(t, func(o *hub.Options) { o.ViewDoor = hub.ViewDoorOff })
	ctx := context.Background()
	ta, _ := e.tenant()
	tb, _ := e.tenant()
	a := e.box(ta, "box-a", "c-004")
	a2 := e.box(ta, "box-a2", "c-005")
	b := e.box(tb, "box-b", "c-006")
	e.pin(ta, a)
	e.pin(ta, a2)
	e.pin(tb, b)
	for _, c := range []struct{ tenant, ch string }{{ta, "deploys"}, {ta, "secret"}, {tb, "deploys"}, {ta, "loose"}} {
		if err := e.st.CreateChannel(ctx, store.Channel{TenantID: c.tenant, ChannelID: c.ch, Name: c.ch, CreatedBy: "wui", CreatedAt: time.Now()}); err != nil {
			t.Fatal(err)
		}
	}
	for ch, boxes := range map[string][]string{"deploys": {"box-a2"}, "secret": {"box-a", "box-a2"}} {
		if err := e.st.SetChannelBoxPins(ctx, ta, ch, boxes, "HUM-1"); err != nil {
			t.Fatal(err)
		}
	}

	want := func(who string, c *hubclient.Client, ch, wantCh string, pinned bool, boxes ...string) {
		t.Helper()
		got, pins, is, err := channelPinsOf(t, c, ch)
		if err != nil || got != wantCh || is != pinned || fmt.Sprint(pins) != fmt.Sprint(boxes) {
			t.Fatalf("%s reads %s: channel=%q box_pins=%v is_pinned=%v err=%v; want %q %v %v", who, ch, got, pins, is, err, wantCh, boxes, pinned)
		}
	}
	// A box of A reads A's pins, a pin it is not on included (the placer
	// asks for any channel); an unpinned channel and a default channel are
	// [] / false (any box).
	want("box-a", a.c, "deploys", "deploys", true, "box-a2")
	want("box-a", a.c, "secret", "secret", true, "box-a", "box-a2")
	want("box-a", a.c, "loose", "loose", false)
	want("box-a", a.c, "lobby", "lobby", false)

	// CONTROL: a box of B asks for "deploys": B's own channel, unpinned,
	// never A's box-a2.
	want("box-b", b.c, "deploys", "deploys", false)
	// CONTROL: a box of B asks for A's "secret": unknown_channel, never A's
	// pins and never an unpinned answer.
	if _, pins, _, err := channelPinsOf(t, b.c, "secret"); err == nil || !strings.Contains(err.Error(), "unknown_channel") {
		t.Fatalf("CONTROL: box-b reads tenant A's #secret: box_pins=%v err=%v, want unknown_channel", pins, err)
	}

	// CONTROL: the frame cannot name workspace A either; the hello's tenant wins.
	raw, err := b.c.Lane(ctx, "channel_pins_get", "", json.RawMessage(`{"channel":"deploys","tenant":"`+ta+`"}`))
	if err != nil || strings.Contains(string(raw), "box-a2") || !strings.Contains(string(raw), `"is_pinned":false`) {
		t.Fatalf("CONTROL: box-b names tenant A in the frame: %s err=%v, want B's unpinned deploys", raw, err)
	}

	// A channel id that is not one is refused; so is a body that is not {channel}.
	if _, _, _, err := channelPinsOf(t, a.c, "No Such!"); err == nil || !strings.Contains(err.Error(), "bad_frame") {
		t.Fatalf("bad channel id: err=%v, want bad_frame", err)
	}
	if _, err := a.c.Lane(ctx, "channel_pins_get", "", json.RawMessage(`[1]`)); err == nil || !strings.Contains(err.Error(), "bad_frame") {
		t.Fatalf("bad body: err=%v, want bad_frame", err)
	}
}

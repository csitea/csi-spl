package action

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/csitea/csi-spl/spool-hub-api/internal/config"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// ChannelPinsArgs is one read of a channel's box pins (spec 164 section 4.3,
// row B4): the verb behind `spool channel-pins`.
type ChannelPinsArgs struct {
	Channel string
	Hub     *hubclient.Client // nil = hubclient.New(cfg)
}

// channelPinsAnswer is the hub's answer; the pointers prove a field was sent.
type channelPinsAnswer struct {
	Channel  string    `json:"channel"`
	BoxPins  *[]string `json:"box_pins"`
	IsPinned *bool     `json:"is_pinned"`
}

// ChannelPins asks the hub, over a one-shot cli session signed by this box's
// key, for one channel's box pins in the box's own workspace, and returns its
// answer {channel, box_pins, is_pinned}. Hub mode only. Any failure is an
// error: no hub, a refusal (unknown_channel), or an answer that is not that
// object. The placer (B5) reads an error as "pinned to nobody", never as
// "unpinned" (spec 164 3.3).
func ChannelPins(ctx context.Context, cfg *config.Config, in ChannelPinsArgs) (json.RawMessage, error) {
	if cfg.HubURL == "" {
		return nil, fmt.Errorf("channel pins need hub mode ($SPOOL_HUB_URL is not set)")
	}
	ch := store.NormalizeChannel(in.Channel)
	if !store.ValidChannelID(ch) {
		return nil, fmt.Errorf("--channel must be a channel id, got %q", in.Channel)
	}
	row, err := json.Marshal(map[string]string{"channel": ch})
	if err != nil {
		return nil, err
	}
	hc := in.Hub
	if hc == nil {
		hc = hubclient.New(cfg)
	}
	raw, err := hc.Lane(ctx, "channel_pins_get", "", row)
	if err != nil {
		return nil, err
	}
	var a channelPinsAnswer
	if err := json.Unmarshal(raw, &a); err != nil || a.BoxPins == nil || a.IsPinned == nil || a.Channel != ch {
		return nil, fmt.Errorf("hub answer is not channel pins JSON for %s: %s", ch, raw)
	}
	return raw, nil
}

package hub

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// A channel's box pins for a box (spec 164 section 4.3, row B4): the placer
// and the launcher (B5) talk to the hub only through the box-signed `spool`
// CLI, so `spool channel-pins --channel <c>` dials a one-shot role=cli
// session signed by the box's own key and asks
//
//	lane_op channel_pins_get {channel}  ->  {channel, box_pins, is_pinned}
//
// for the ASKING box's workspace only (x.tenant from the hello; the frame
// cannot name another). A channel that workspace does not know
// (store.ChannelKnown) is 404 unknown_channel, never an unpinned answer: B5 fails closed
// on any error (spec 164 3.3). box_pins is never null; [] = unpinned, any box.
type boxChannelPins struct {
	Channel  string   `json:"channel"`
	BoxPins  []string `json:"box_pins"`
	IsPinned bool     `json:"is_pinned"`
}

// isBoxChannelPinsLaneOp routes a lane frame to onBoxChannelPinsLane.
func isBoxChannelPinsLaneOp(op string) bool { return op == "channel_pins_get" }

// onBoxChannelPinsLane answers channel_pins_get; the reply rides the lane
// field of a lane frame, as box_presence_get's does.
func (s *Server) onBoxChannelPinsLane(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a lane frame needs msg_id (a UUID) to pair the reply")
		return
	}
	var in struct {
		Channel string `json:"channel"`
	}
	if err := json.Unmarshal(f.Lane, &in); err != nil {
		x.fail(ctx, id, "bad_frame", http.StatusBadRequest, "lane must be {channel}")
		return
	}
	out, ae := s.boxChannelPins(ctx, x.tenant, in.Channel)
	if ae != nil {
		x.fail(ctx, id, ae.token, ae.status, ae.detail)
		return
	}
	raw, err := json.Marshal(out)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TLane, MsgID: id, LaneOp: f.LaneOp, Fleet: f.Fleet, Lane: raw}) //nolint:errcheck
}

// boxChannelPins is one channel's pins in tenant; an unknown channel or a
// failed lookup is an error, never "unpinned".
func (s *Server) boxChannelPins(ctx context.Context, tenant, channel string) (boxChannelPins, *issueErr) {
	ch := store.NormalizeChannel(channel)
	if !store.ValidChannelID(ch) {
		return boxChannelPins{}, &issueErr{http.StatusBadRequest, "bad_frame", "channel must be a channel id"}
	}
	switch known, err := s.o.Store.ChannelKnown(ctx, tenant, ch); {
	case err != nil:
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("channel", ch).Msg("box channel pins: channel lookup")
		return boxChannelPins{}, &issueErr{http.StatusInternalServerError, "internal", "channel lookup failed"}
	case !known:
		return boxChannelPins{}, &issueErr{http.StatusNotFound, "unknown_channel", "no channel " + ch + " in this tenant"}
	}
	boxes, err := s.o.Store.GetChannelBoxPins(ctx, tenant, ch)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", tenant).Str("channel", ch).Msg("box channel pins")
		return boxChannelPins{}, &issueErr{http.StatusInternalServerError, "internal", "channel box pins unavailable"}
	}
	if boxes == nil {
		boxes = []string{}
	}
	return boxChannelPins{Channel: ch, BoxPins: boxes, IsPinned: len(boxes) > 0}, nil
}

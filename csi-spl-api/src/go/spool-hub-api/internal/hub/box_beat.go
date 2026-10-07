package hub

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The box beat of spec 102 section 10.2 (rdb 0147, task T017). Every box's
// watchdog beats once per tick over the authenticated hello on a one-shot
// role=cli session (`spool box-beat put`); the writing box comes from the
// session, never the frame, and beat_at is the hub's clock:
//
//	lane_op box_beat_put   {pid} -> the ACK {ok, box, beat_at, box_down_min}
//	lane_op box_beat_list  {box?, since?} -> {box, since, rows} newest first
//
// box_down_min is the lifetime setting in force (rdb 0145, spec 102 11.1):
// the box fences itself when no ack came for that long (spl_wd_fence).

const boxBeatsSinceDefault = 10 * time.Minute

// boxBeatAck is the reply to a beat.
type boxBeatAck struct {
	OK         bool   `json:"ok"`
	Box        string `json:"box"`
	BeatAt     string `json:"beat_at"`
	BoxDownMin int    `json:"box_down_min"`
}

// isBoxBeatLaneOp routes a lane frame to onBoxBeatLane.
func isBoxBeatLaneOp(op string) bool { return strings.HasPrefix(op, "box_beat_") }

// sweepBoxBeats is the 2-day retention, on the hub's retention sweep.
func (s *Server) sweepBoxBeats(ctx context.Context) {
	bb, ok := s.o.Store.(store.BoxBeats)
	if !ok {
		return
	}
	n, err := bb.PruneBoxBeats(ctx, s.o.Now().Add(-store.BoxBeatsRetention))
	if err != nil {
		s.o.Log.Error().Err(err).Msg("box_beats retention sweep")
		return
	}
	if n > 0 {
		s.o.Log.Info().Int("pruned", n).Msg("box_beats retention sweep")
	}
}

// onBoxBeatLane answers a box_beat lane frame; the reply rides the lane field
// of a lane frame, as box_stats' does.
func (s *Server) onBoxBeatLane(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a lane frame needs msg_id (a UUID) to pair the reply")
		return
	}
	out, ae := s.boxBeatFrame(ctx, x, f)
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

func (s *Server) boxBeatFrame(ctx context.Context, x *session, f wire.Frame) (any, *issueErr) {
	bb, ok := s.o.Store.(store.BoxBeats)
	if !ok {
		return nil, &issueErr{http.StatusNotImplemented, "unsupported", "this hub's store keeps no box beats"}
	}
	switch f.LaneOp {
	case "box_beat_put":
		var in struct {
			PID int `json:"pid"`
		}
		dec := json.NewDecoder(bytes.NewReader(f.Lane))
		dec.DisallowUnknownFields()
		if err := dec.Decode(&in); err != nil {
			return nil, &issueErr{http.StatusBadRequest, "bad_frame", "lane must be {pid}"}
		}
		b := store.BoxBeat{Box: x.box, BeatAt: s.o.Now(), PID: in.PID}
		if why := store.CheckBoxBeat(b); why != "" {
			return nil, &issueErr{http.StatusBadRequest, "bad_frame", why}
		}
		if err := bb.AppendBoxBeat(ctx, x.tenant, b); err != nil {
			s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("box beat append")
			return nil, &issueErr{http.StatusInternalServerError, "internal", "box beat not stored"}
		}
		return boxBeatAck{OK: true, Box: b.Box, BeatAt: b.BeatAt.UTC().Format(time.RFC3339), BoxDownMin: s.boxDownMin(ctx)}, nil
	case "box_beat_list":
		var q struct {
			Box   string `json:"box"`
			Since string `json:"since"`
		}
		if len(f.Lane) > 0 {
			if err := json.Unmarshal(f.Lane, &q); err != nil {
				return nil, &issueErr{http.StatusBadRequest, "bad_frame", "lane must be {box, since}"}
			}
		}
		if q.Box != "" && !store.FleetNameRe.MatchString(q.Box) {
			return nil, &issueErr{http.StatusBadRequest, "bad_frame", "box must be a box id ([a-z0-9-], up to 32)"}
		}
		since := s.o.Now().Add(-boxBeatsSinceDefault)
		if q.Since != "" {
			d, err := time.ParseDuration(q.Since)
			if err != nil || d <= 0 {
				return nil, &issueErr{http.StatusBadRequest, "bad_frame", "since is a duration back from now (10m, 2h)"}
			}
			since = s.o.Now().Add(-d)
		}
		rows, err := bb.ListBoxBeats(ctx, x.tenant, q.Box, since)
		if err != nil {
			s.o.Log.Error().Err(err).Str("tenant", x.tenant).Msg("box beats list")
			return nil, &issueErr{http.StatusInternalServerError, "internal", "box beats unavailable"}
		}
		return map[string]any{"box": q.Box, "since": since.UTC().Format(time.RFC3339), "rows": rows}, nil
	}
	return nil, &issueErr{http.StatusBadRequest, "bad_frame", "lane_op must be box_beat_put or box_beat_list"}
}

// boxDownMin is the box_down_min in force; its default when the setting
// cannot be read (the beat is stored either way: the ack must not fail on it).
func (s *Server) boxDownMin(ctx context.Context) int {
	def := 2
	for _, k := range store.LifecycleKeys {
		if d, ok := k.Default.(int); ok && k.Key == "box_down_min" {
			def = d
		}
	}
	vals, _, err := store.ReadLifetimeSettings(ctx, s.o.Store, s.o.OperatorTenant)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("box_down_min read")
		return def
	}
	switch v := vals["box_down_min"].(type) {
	case int:
		return v
	case int64:
		return int(v)
	case float64:
		return int(v)
	}
	return def
}

package hub

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Box presence for the box itself (SPL-5318, spec 069 8.4: the desk move's
// proof). A desk proves it is live with the key it holds, with no member
// login: `spool box-presence` dials a one-shot role=cli session signed by the
// desk's own key and asks
//
//	lane_op box_presence_get   {box, socket, agents}
//
// for the ASKING box only (x.box in x.tenant; no other box can be named).
//
// socket is true only while THIS hub instance holds a role=box socket for the
// box (s.boxes). It never reads boxes.last_hello_at: every hello, role=cli
// included, re-stamps that column (seatSession -> TouchBox), so a probe read
// from it would see the box online for presenceTTL with its sidecar dead. The
// asking cli session is never in s.boxes (register adds role=box only).
//
// The answer is per instance: with two instances (cnf hub max_instances) a
// box whose socket is on the other one reads socket false here. A false is
// "not seen on this instance", never proof of down; a true is a live socket.
// The caller retries (csi-spl-orc _spl_dm_proof), each dial a fresh pick.
//
// agents is the box's roster row (the agents its hello seated), sorted.
type boxPresence struct {
	Box    string   `json:"box"`
	Socket bool     `json:"socket"`
	Agents []string `json:"agents"`
}

// isBoxPresenceLaneOp routes a lane frame to onBoxPresenceLane.
func isBoxPresenceLaneOp(op string) bool { return op == "box_presence_get" }

// onBoxPresenceLane answers box_presence_get; the reply rides the lane field
// of a lane frame, as fleet_load_get's does.
func (s *Server) onBoxPresenceLane(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a lane frame needs msg_id (a UUID) to pair the reply")
		return
	}
	out, err := s.boxPresence(ctx, x.tenant, x.box)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("box presence")
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "box presence unavailable")
		return
	}
	raw, err := json.Marshal(out)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TLane, MsgID: id, LaneOp: f.LaneOp, Fleet: f.Fleet, Lane: raw}) //nolint:errcheck
}

// boxPresence is the box's socket on this instance and its roster agents.
func (s *Server) boxPresence(ctx context.Context, tenant, box string) (boxPresence, error) {
	out := boxPresence{Box: box, Agents: []string{}}
	if x := s.boxSession(tenant, box); x != nil && x.role == wire.RoleBox {
		out.Socket = true
	}
	r, err := s.o.Store.Roster(ctx, tenant)
	if err != nil {
		return boxPresence{}, err
	}
	if a := r[box]; a != nil {
		out.Agents = a
	}
	return out, nil
}

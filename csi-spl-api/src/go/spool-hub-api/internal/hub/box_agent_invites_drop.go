package hub

import (
	"context"
	"encoding/json"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// A retired agent id leaves every channel it was invited to (spec 061 3.6,
// SPL-6714). Ids are reused after the quarantine, and the only remove door,
// DELETE /v1/channels/{c}/agents/{box}/{id}, needs a member session, so a
// box could not end a seat: the next holder of the id inherited every
// channel the old one was invited to. agent-id-retire.sh now asks, through
// `spool agent-invites-drop`, a one-shot role=cli session signed by the
// desk's own key:
//
//	lane_op agent_invites_drop {agent[, box]}  ->  {agent, box, channels}
//
// for the ASKING box (x.box) in its own workspace (x.tenant) only. A frame
// that names another box is refused (403 forbidden): a box drops only its
// own ids. channels lists the channels whose seat went to 'removed' ([]
// when none). History and agent_seats stay. The humans-only mark
// (SPL-2423) is not set: it records what a PERSON did to the member list.
type agentInvitesDrop struct {
	Agent    string   `json:"agent"`
	Box      string   `json:"box"`
	Channels []string `json:"channels"`
}

// isAgentInvitesDropLaneOp routes a lane frame to onAgentInvitesDropLane.
func isAgentInvitesDropLaneOp(op string) bool { return op == "agent_invites_drop" }

// onAgentInvitesDropLane answers agent_invites_drop; the reply rides the
// lane field of a lane frame, as channel_pins_get's does.
func (s *Server) onAgentInvitesDropLane(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a lane frame needs msg_id (a UUID) to pair the reply")
		return
	}
	var in struct {
		Agent string `json:"agent"`
		Box   string `json:"box"`
	}
	if err := json.Unmarshal(f.Lane, &in); err != nil {
		x.fail(ctx, id, "bad_frame", http.StatusBadRequest, "lane must be {agent[, box]}")
		return
	}
	out, ae := s.agentInvitesDrop(ctx, x, in.Agent, in.Box)
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

// agentInvitesDrop checks the ask and drops the seats of agent on x.box.
func (s *Server) agentInvitesDrop(ctx context.Context, x *session, agent, box string) (agentInvitesDrop, *issueErr) {
	if !isAgentID(agent) {
		return agentInvitesDrop{}, &issueErr{http.StatusBadRequest, "bad_frame", "agent must be an agent id"}
	}
	if box != "" && box != x.box {
		return agentInvitesDrop{}, &issueErr{http.StatusForbidden, "forbidden", "a box drops only its own agents' invites: " + box + " is not " + x.box}
	}
	ai, ok := s.o.Store.(store.AgentInvites)
	if !ok {
		return agentInvitesDrop{}, &issueErr{http.StatusNotImplemented, "unsupported", "this store cannot drop invites"}
	}
	chs, err := ai.DropAgentInvites(ctx, x.tenant, x.box, agent, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("box", x.box).Str("agent", agent).Msg("agent invites drop")
		return agentInvitesDrop{}, &issueErr{http.StatusInternalServerError, "internal", "agent invites not dropped"}
	}
	if chs == nil {
		chs = []string{}
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("agent", agent).
		Strs("channels", chs).Msg("agent invites dropped (retire)")
	return agentInvitesDrop{Agent: agent, Box: x.box, Channels: chs}, nil
}

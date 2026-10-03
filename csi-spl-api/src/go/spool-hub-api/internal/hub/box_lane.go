package hub

import (
	"context"
	"encoding/json"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The fleet-wide lane map (CLE-77920, specs/058 G4): who owns what across
// every machine of a fleet. `git worktree list` sees one machine's lanes
// only, so the spawn path writes a row per agent here and every machine's
// collision check reads all of them. Lane frames ride a one-shot role=cli
// session:
//
//	lane_op put  - upsert the row of lane.agent_id (spawn: live, exit: done)
//	lane_op list - every row of the fleet, live first
//
// A row is the agent <agent_id>@<agent_box> (the fleet naming rule).
// Who may: any box pinned in the tenant (the hello proved its key); the
// writing box is recorded from the session, never from the frame.

// LaneRow is one row on the wire, in both directions.
type LaneRow struct {
	AgentID   string   `json:"agent_id"`
	AgentBox  string   `json:"agent_box"`
	Repo      string   `json:"repo"`
	Branch    string   `json:"branch"`
	Scope     string   `json:"scope"`
	Files     []string `json:"files"`
	Topic     string   `json:"topic"`
	State     string   `json:"state"`
	WriterBox string   `json:"writer_box,omitempty"`
	UpdatedAt string   `json:"updated_at,omitempty"`
	AgeS      int64    `json:"age_s"`
}

// laneAnswer is the reply object.
type laneAnswer struct {
	Fleet string    `json:"fleet"`
	Lanes []LaneRow `json:"lanes"`
}

func laneRow(l store.FleetLane) LaneRow {
	return LaneRow{AgentID: l.AgentID, AgentBox: l.AgentBox, Repo: l.Repo, Branch: l.Branch, Scope: l.Scope,
		Files: l.Files, Topic: l.Topic, State: l.State, WriterBox: l.WriterBox,
		UpdatedAt: l.UpdatedAt.UTC().Format(time.RFC3339), AgeS: int64(l.Age.Seconds())}
}

// onLane answers a lane frame.
func (s *Server) onLane(ctx context.Context, x *session, f wire.Frame) {
	if isLifecycleLaneOp(f.LaneOp) { // spec 063: the lifecycle config + event log
		s.onLifecycleLane(ctx, x, f)
		return
	}
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a lane frame needs msg_id (a UUID) to pair the reply")
		return
	}
	out, ae := s.boxLane(ctx, x, f)
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

// boxLane checks the frame and writes or lists the rows.
func (s *Server) boxLane(ctx context.Context, x *session, f wire.Frame) (laneAnswer, *issueErr) {
	if !store.FleetNameRe.MatchString(f.Fleet) {
		return laneAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "fleet must be a lowercase slug ([a-z0-9-], up to 32)"}
	}
	now := s.o.Now()
	out := laneAnswer{Fleet: f.Fleet, Lanes: []LaneRow{}}
	switch f.LaneOp {
	case "put":
		var in LaneRow
		if err := json.Unmarshal(f.Lane, &in); err != nil {
			return laneAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "lane must be a lane row object"}
		}
		agent, ae := s.resolveAgent(ctx, x.tenant, in.AgentID, in.AgentBox)
		if ae != nil {
			return laneAnswer{}, ae
		}
		l := store.FleetLane{Fleet: f.Fleet, AgentID: agent, AgentBox: in.AgentBox, Repo: in.Repo, Branch: in.Branch,
			Scope: in.Scope, Files: in.Files, Topic: in.Topic, State: in.State}
		if why := store.CheckFleetLane(l); why != "" {
			return laneAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", why}
		}
		got, err := s.o.Store.PutFleetLane(ctx, x.tenant, l, x.box, now)
		if err != nil {
			s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Str("agent", l.AgentID).Msg("fleet lane store")
			return laneAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "lane map unavailable"}
		}
		s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("fleet", f.Fleet).Str("agent", got.AgentID).
			Str("agent_box", got.AgentBox).Str("state", got.State).Msg("fleet lane put")
		out.Lanes = append(out.Lanes, laneRow(got))
	case "list":
		ls, err := s.o.Store.ListFleetLanes(ctx, x.tenant, f.Fleet, now)
		if err != nil {
			s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Msg("fleet lane list")
			return laneAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "lane map unavailable"}
		}
		for _, l := range ls {
			out.Lanes = append(out.Lanes, laneRow(l))
		}
	default:
		return laneAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "lane_op must be put or list"}
	}
	return out, nil
}

package hub

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// lane_op archived (SPL-3983; owner HUM-10, 2026-10-27: "the discusoin has
// been archieved -> the agents should be killed / freed"): the live lanes of
// the fleet whose topic is archived, read only. The box action
// do_spl_archived_seats_free frees each one it hosts, by code.
//
// The frame's lane object may name agent_box: only that box's rows answer.
// A row's topic is the uuid the put stored (laneTopic). It is read in the
// session's tenant first; for a box of the operator workspace, a topic that
// tenant does not hold is read in the other workspaces, as the put found it
// (laneTopicElsewhere). Each answered row carries topic_archived_at, the
// stamp that hides the topic from every list (store.TopicArchived). A live,
// deleted or non-uuid topic answers nothing, so a doubt never frees a lane.

// laneArchived answers the live lanes whose topic is archived.
func (s *Server) laneArchived(ctx context.Context, x *session, f wire.Frame, now time.Time) (laneAnswer, *issueErr) {
	var want struct {
		AgentBox string `json:"agent_box"`
	}
	if len(f.Lane) > 0 && string(f.Lane) != "null" {
		if err := json.Unmarshal(f.Lane, &want); err != nil {
			return laneAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "lane must be an object, e.g. {\"agent_box\": \"<box>\"}"}
		}
	}
	ls, err := s.o.Store.ListFleetLanes(ctx, x.tenant, f.Fleet, now)
	if err != nil {
		s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Msg("fleet lane archived list")
		return laneAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "lane map unavailable"}
	}
	out := laneAnswer{Fleet: f.Fleet, Lanes: []LaneRow{}}
	stamp := map[string]time.Time{}
	for _, l := range ls {
		if l.State != "live" || !uuidRe.MatchString(l.Topic) || (want.AgentBox != "" && l.AgentBox != want.AgentBox) {
			continue
		}
		at, seen := stamp[l.Topic]
		if !seen {
			if at, err = s.laneTopicArchivedAt(ctx, x.tenant, l.Topic); err != nil {
				s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Msg("fleet lane topic archive read")
				return laneAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "lane map unavailable"}
			}
			stamp[l.Topic] = at
		}
		if at.IsZero() {
			continue
		}
		r := laneRow(l)
		r.TopicArchivedAt = at.UTC().Format(time.RFC3339)
		out.Lanes = append(out.Lanes, r)
	}
	return out, nil
}

// laneTopicArchivedAt is topic's archive stamp, zero for a live or unknown
// topic: in tenant, else (tenant the operator workspace, and the topic not
// one of its own) in the first other live workspace that archived it.
func (s *Server) laneTopicArchivedAt(ctx context.Context, tenant, topic string) (time.Time, error) {
	at, _, err := s.o.Store.TopicArchived(ctx, tenant, topic, s.o.LobbyTaskID)
	if err != nil || !at.IsZero() {
		return at, err
	}
	if d, ok := s.issueDiscussionStore(); ok {
		own, err := d.TopicsByPrefix(ctx, tenant, topic[:8], 2)
		if err != nil || slices.Contains(own, topic) {
			return time.Time{}, err
		}
	}
	op, err := s.operatorTenant(ctx)
	ws, listed := s.o.Store.(store.OperatorWorkspaces)
	if err != nil || op == "" || op != tenant || !listed {
		return time.Time{}, err
	}
	all, err := ws.ListWorkspaces(ctx)
	if err != nil {
		return time.Time{}, err
	}
	for _, w := range all {
		if w.ID == op || !w.ArchivedAt.IsZero() {
			continue
		}
		if at, _, err = s.o.Store.TopicArchived(ctx, w.ID, topic, s.o.LobbyTaskID); err != nil || !at.IsZero() {
			return at, err
		}
	}
	return time.Time{}, nil
}

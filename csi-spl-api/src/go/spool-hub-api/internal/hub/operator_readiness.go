package hub

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The readiness of a workspace (spec 158 section 10.8, row V1, SPL-5027):
// each step U1..U6 of section 10.1, read from what the hub already stores, so
// a stuck step reads in the operator page (row V2) with no agent looking.
//
//	GET /v1/operator/workspaces/{id}/readiness
//	  {workspace, read_at, steps: [{step, u, state, detail, at?, row?}]}
//
//	step          u   state                                    read from
//	invite        U1  not_sent | sent | accepted (U2)          tenant_invites, the members
//	host          U3  waiting | ready | failed | removing |    tenant_hosts
//	                  removed | missing
//	docs          U4  waiting | ok | unavailable | unknown     the workspace docs store, once the host is ready
//	pin           U5  ok | missing | revoked | other_key |     the box-wui pin against this hub's key
//	                  unknown
//	seats         U6  seated | waiting | unknown               fleet_desk_boxes, the workspace's pins and roster
//	first_answer  U6  no_post | waiting | answered             the newest topics: a member post, then an agent's
//
// unknown never guesses: it says what is not stored, and row names the row of
// tasks.md section 6 that will store it. A pending host with no detail is
// waiting, with row H3 (the reconcile writes the wait reason from then on).
// Read-only, the operator workspace's admin only (operatorActor: anyone else
// 403), one AuditRead row as GET /v1/operator/workspaces/{id}. The body holds
// no topic, message, member or key of the workspace: states, counts and times.

// Readiness step states.
const (
	readyUnknown  = "unknown"
	readyWaiting  = "waiting"
	readyOK       = "ok"
	readyNotSent  = "not_sent"
	readySent     = "sent"
	readyAccepted = "accepted"
	readyMissing  = "missing"
	readySeated   = "seated"
	readyNoPost   = "no_post"
	readyAnswered = "answered"
)

// readinessTopics is how many of the newest topics first_answer reads;
// readinessTopicMsgs how many messages of each, oldest first.
const (
	readinessTopics    = 20
	readinessTopicMsgs = 50
)

// readyStep is one step of the readiness body.
type readyStep struct {
	Step   string  `json:"step"`
	U      string  `json:"u"`
	State  string  `json:"state"`
	Detail string  `json:"detail"`
	At     *string `json:"at,omitempty"`
	Row    string  `json:"row,omitempty"`
}

func (s *Server) routeOperatorReadiness(mux *http.ServeMux) {
	mux.HandleFunc("GET /v1/operator/workspaces/{id}/readiness", s.handleOperatorReadiness)
	mux.HandleFunc("OPTIONS /v1/operator/workspaces/{id}/readiness", s.operatorWorkspacesPreflight)
}

// GET /v1/operator/workspaces/{id}/readiness
func (s *Server) handleOperatorReadiness(w http.ResponseWriter, r *http.Request) {
	a, ok := s.operatorActor(w, r)
	if !ok {
		return
	}
	ws, ok := s.workspaceTarget(w, r, a)
	if !ok {
		return
	}
	steps, err := s.readiness(r.Context(), ws.ID)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", ws.ID).Msg("operator readiness")
		writeErr(w, http.StatusInternalServerError, "internal", "readiness not read")
		return
	}
	s.opAudit(r, a, ws.ID, store.AuditRead, map[string]any{"readiness": true})
	writeJSON(w, http.StatusOK, map[string]any{"workspace": ws.ID, "read_at": rfc(s.o.Now().UTC()), "steps": steps})
}

// readiness reads the six steps of workspace id, in order.
func (s *Server) readiness(ctx context.Context, id string) ([]readyStep, error) {
	invite, err := s.readyInvite(ctx, id)
	if err != nil {
		return nil, err
	}
	host, err := s.readyHost(ctx, id)
	if err != nil {
		return nil, err
	}
	boxes, err := s.o.Store.ViewBoxes(ctx, id)
	if err != nil {
		return nil, err
	}
	seats, err := s.readySeats(ctx, boxes)
	if err != nil {
		return nil, err
	}
	answer, err := s.readyFirstAnswer(ctx, id)
	if err != nil {
		return nil, err
	}
	return []readyStep{invite, host, s.readyDocs(ctx, id, host), s.readyPin(boxes), seats, answer}, nil
}

// readyInvite is U1 and U2: a member who came in by an invite is accepted;
// else an unaccepted invite is sent once mailed, not_sent before.
func (s *Server) readyInvite(ctx context.Context, id string) (readyStep, error) {
	st := readyStep{Step: "invite", U: "U1"}
	md, ok := s.o.Store.(store.MemberDirectory)
	if !ok {
		st.State, st.Detail = readyUnknown, "this hub's store keeps no member directory"
		return st, nil
	}
	members, err := md.ListMembers(ctx, id)
	if err != nil {
		return st, err
	}
	for _, m := range members {
		if !m.InvitedOn.IsZero() {
			st.U, st.State, st.Detail, st.At = "U2", readyAccepted, "an invited person is a member", rfcOrNil(m.Since)
			return st, nil
		}
	}
	invites, err := md.ListInvites(ctx, id)
	if err != nil {
		return st, err
	}
	st.State, st.Detail = readyNotSent, "no invite stored"
	var mailed time.Time
	for _, p := range invites {
		switch {
		case p.MailedAt != nil && p.MailedAt.After(mailed):
			mailed = *p.MailedAt
			st.State, st.Detail, st.At = readySent, "mailed, not accepted yet", rfcOrNil(mailed)
		case st.State == readyNotSent:
			st.Detail, st.At = "stored, never mailed", rfcOrNil(p.CreatedAt)
		}
	}
	return st, nil
}

// readyHost is U3, the tenant_hosts row as it stands.
func (s *Server) readyHost(ctx context.Context, id string) (readyStep, error) {
	st := readyStep{Step: "host", U: "U3"}
	h, err := s.o.Store.TenantHost(ctx, id)
	switch {
	case errors.Is(err, store.ErrNotFound):
		st.State, st.Detail = readyMissing, "no tenant_hosts row"
		return st, nil
	case err != nil:
		return st, err
	}
	st.State, st.Detail, st.At = h.Status, h.Detail, rfcOrNil(h.UpdatedAt)
	if h.Status == store.HostPending {
		st.State = readyWaiting
		if h.Detail == "" {
			st.Detail, st.Row = "no reason recorded", "H3"
		}
	}
	return st, nil
}

// errStopList ends the docs probe at its first object.
var errStopList = errors.New("readiness: stop")

// readyDocs is U4: the docs bucket is applied with the host, so it waits for
// it; once the host is ready, the workspace's docs store must answer a list.
func (s *Server) readyDocs(ctx context.Context, id string, host readyStep) readyStep {
	st := readyStep{Step: "docs", U: "U4"}
	switch {
	case host.State != store.HostReady:
		st.State, st.Detail = readyWaiting, "follows the host: its bucket is applied with it"
		return st
	case s.o.WorkspaceDocs == nil:
		st.State, st.Detail = readyUnknown, "this hub serves no workspace docs"
		return st
	}
	bs, err := s.o.WorkspaceDocs.Store(ctx, id)
	if err == nil {
		err = bs.List(ctx, "", func(string, time.Time) error { return errStopList })
	}
	if err != nil && !errors.Is(err, errStopList) {
		s.o.Log.Error().Err(err).Str("workspace", id).Msg("readiness docs probe")
		st.State, st.Detail = "unavailable", "the docs store did not answer a list"
		return st
	}
	st.State, st.Detail = readyOK, "the docs store answers"
	return st
}

// readyPin is U5: box-wui pinned to this hub's key signs the browser posts.
func (s *Server) readyPin(boxes []store.ViewBox) readyStep {
	st := readyStep{Step: "pin", U: "U5", State: readyMissing, Detail: "no " + WUIBox + " pin row"}
	for _, b := range boxes {
		if b.BoxID != WUIBox {
			continue
		}
		pub := s.wuiPub()
		switch {
		case b.Revoked:
			st.State, st.Detail = "revoked", WUIBox+" pin is revoked"
		case pub == nil:
			st.State, st.Detail = readyUnknown, "this hub has no "+WUIBox+" key to compare"
		case !pub.Equal(b.PubKey):
			st.State, st.Detail = "other_key", WUIBox+" is pinned to a key that is not this hub's"
		default:
			st.State, st.Detail = readyOK, WUIBox+" is pinned to this hub's key"
		}
	}
	return st
}

// readySeats is U6's seats: an agent in the roster of a live box is seated;
// else the listed fleet desk boxes say whether seats can come.
func (s *Server) readySeats(ctx context.Context, boxes []store.ViewBox) (readyStep, error) {
	st := readyStep{Step: "seats", U: "U6"}
	live, agents := map[string]bool{}, 0
	for _, b := range boxes {
		if b.Revoked || b.BoxID == WUIBox {
			continue
		}
		live[b.BoxID] = true
		agents += len(b.Agents)
	}
	var desks []store.FleetDeskBox
	if fd, ok := s.o.Store.(store.FleetDeskBoxes); ok {
		var err error
		if desks, err = fd.ListFleetDeskBoxes(ctx); err != nil {
			return st, err
		}
	}
	pinned := 0
	for _, d := range desks {
		if live[d.BoxID] {
			pinned++
		}
	}
	counts := fmt.Sprintf("%d of %d listed desk boxes pinned here, %d agents in the roster", pinned, len(desks), agents)
	switch {
	case agents > 0:
		st.State, st.Detail = readySeated, counts
	case len(desks) == 0:
		st.State, st.Detail, st.Row = readyUnknown, "no fleet desk box is listed, so nothing seats this workspace", "S2"
	default:
		st.State, st.Detail = readyWaiting, counts
	}
	return st, nil
}

// readyFirstAnswer is U6's answer: in the newest topics, a member's post
// (from box-wui) followed by a message from any other box.
func (s *Server) readyFirstAnswer(ctx context.Context, id string) (readyStep, error) {
	st := readyStep{Step: "first_answer", U: "U6", State: readyNoPost, Detail: "no member post in the newest topics"}
	now := s.o.Now()
	topics, err := s.o.Store.ViewTopics(ctx, id, store.TopicQuery{NoIssues: true, Limit: readinessTopics, Now: now})
	if err != nil {
		return st, err
	}
	var since time.Time
	for _, t := range topics {
		msgs, err := s.o.Store.ViewTopic(ctx, id, store.TopicMsgQuery{TaskID: t.TaskID, Limit: readinessTopicMsgs, Now: now})
		if err != nil {
			return st, err
		}
		posted, answered := topicAnswer(msgs)
		if !answered.IsZero() {
			st.State, st.Detail, st.At = readyAnswered, "an agent answered a member's post", rfcOrNil(answered)
			return st, nil
		}
		if !posted.IsZero() && (since.IsZero() || posted.Before(since)) {
			since = posted
		}
	}
	if !since.IsZero() {
		st.State, st.Detail, st.At = readyWaiting, "a member posted, no agent answered yet", rfcOrNil(since)
	}
	return st, nil
}

// topicAnswer is the first member post of msgs (oldest first) and the first
// message from another box after it; zero when there is none.
func topicAnswer(msgs []store.ViewMsg) (posted, answered time.Time) {
	for _, m := range msgs {
		var env struct {
			FromBox string `json:"from_box"`
		}
		if json.Unmarshal(m.Env, &env) != nil || env.FromBox == "" {
			continue
		}
		switch {
		case env.FromBox == WUIBox && posted.IsZero():
			posted = m.ReceivedAt
		case env.FromBox != WUIBox && !posted.IsZero():
			return posted, m.ReceivedAt
		}
	}
	return posted, time.Time{}
}

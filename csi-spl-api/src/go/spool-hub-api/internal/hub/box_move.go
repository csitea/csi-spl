package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/billing"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// A box agent moves a topic to another channel of its workspace by the
// topic's task id (owner HUM-10, t1 b316397f: "Move both the specification
// and the implementation discussion for the calendar feature to the dev
// channel", and "My responsibility shouldn't be to copy-paste simple
// commands"). It is the box twin of the browser's POST
// /v1/messages/{card}/move {to_channel} (spec 045 §3.1): the same card
// (store.TaskCard), the same refusals, and the same write, storeTopicMove -
// MoveTopic, the moved_by mark, the log line and the topic_moved frame.
//
// Who may is spec 041 §3.3 read for an agent:
//   - the agent that started the topic: the card was sent by this box AS
//     this agent (from_box and from_id both match);
//   - an agent acting for a workspace owner or admin: typed_by names that
//     HUM-*, a member a box_operators binding (rdb 0040, granted by an owner
//     or admin, never by a box) says operates this box - the typed_by rule of
//     specs/036 FR-010 - and that human is the tenant owner or an admin.
//
// Nothing else: another agent of the same box, a bound developer, or an
// unbound human is not_allowed. The topic must be one the mover reads (the
// box's tail rule, or the acted-for human's channel door; else not_found),
// and the target a channel the mover may post in (the agent is a member, or
// the acted-for human reads it; else unknown_channel, rdb 0028). moved_by is
// the acting agent; the human it acts for is logged as acting_for.

// onMove answers a move frame.
func (s *Server) onMove(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a move frame needs msg_id (a UUID) to pair the reply")
		return
	}
	out, ie := s.boxMove(ctx, x, f)
	if ie != nil {
		x.fail(ctx, id, ie.token, ie.status, ie.detail)
		return
	}
	raw, err := json.Marshal(out)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TMove, MsgID: id, TaskID: f.TaskID, Move: raw}) //nolint:errcheck
}

// boxMove resolves and gates the topic and the target, then moves it.
func (s *Server) boxMove(ctx context.Context, x *session, f wire.Frame) (map[string]any, *issueErr) {
	task := f.TaskID
	if !uuidRe.MatchString(task) || task != strings.ToLower(task) {
		return nil, &issueErr{http.StatusBadRequest, "bad_frame", "a move frame needs task_id, the topic's lowercase UUID"}
	}
	ch := store.NormalizeChannel(strings.ToLower(strings.TrimPrefix(f.MoveTo, "#")))
	if ch == "" {
		return nil, &issueErr{http.StatusBadRequest, "bad_frame", "a move frame needs move_to, the target channel"}
	}
	if detail := senderRefusal(x, f.As); detail != "" {
		return nil, &issueErr{http.StatusForbidden, TokenFromNotAnnounced, detail}
	}
	hum := f.TypedBy
	if hum != "" {
		if detail := s.typedByRefusal(ctx, x, f.As, hum); detail != "" {
			return nil, &issueErr{http.StatusForbidden, "not_allowed", detail}
		}
	}
	t, err := s.o.Store.GetTenant(ctx, x.tenant)
	if err != nil {
		return nil, &issueErr{http.StatusInternalServerError, "internal", "tenant unavailable"}
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		return nil, &issueErr{billing.HTTPUnpaid, billing.TokenUnpaid, "tenant billing is unpaid"}
	}
	if s.o.LobbyTaskID != "" && task == s.o.LobbyTaskID {
		return nil, &issueErr{http.StatusConflict, "lobby", moveRefusals["lobby"]}
	}
	now := s.o.Now()
	card, err := s.o.Store.TaskCard(ctx, x.tenant, task, now)
	var m store.EditableMessage
	if err == nil {
		m, err = s.o.Store.GetEditable(ctx, x.tenant, card.MsgID, now)
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		return nil, &issueErr{http.StatusNotFound, "not_found", "no such topic"}
	case err != nil:
		s.o.Log.Error().Err(err).Str("task_id", task).Msg("box move lookup")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "topic unavailable"}
	}
	if !s.boxMoverReads(ctx, x, m, hum) {
		return nil, &issueErr{http.StatusNotFound, "not_found", "no such topic"}
	}
	refuse := func(token string) (map[string]any, *issueErr) {
		return nil, &issueErr{http.StatusConflict, token, moveRefusals[token]}
	}
	switch {
	case m.Channel == "":
		return refuse("not_in_channel")
	case card.IssueTopic:
		return refuse("issue_topic")
	}
	if !s.boxMayMove(ctx, x, m, f.As, hum) {
		return nil, &issueErr{http.StatusForbidden, "not_allowed",
			"only the agent that started this topic, or an agent acting for a workspace owner or admin, may move it"}
	}
	switch {
	case ch == store.ChannelLobby:
		return refuse("lobby")
	case ch == m.Channel:
		return refuse("same_place")
	}
	if ie := s.targetChannel(ctx, x.tenant, ch, func() (bool, error) {
		in, err := s.agentInChannel(ctx, x.tenant, ch, x.box, f.As)
		if err != nil || in || hum == "" {
			return in, err
		}
		return s.canReadChannel(ctx, x.tenant, ch, hum)
	}); ie != nil {
		return nil, ie
	}
	return s.storeTopicMove(ctx, x.tenant, m, ch, f.As, hum)
}

// boxMoverReads is the read door on the card: the box's tail rule, or, for an
// agent acting for a human, that human's channel door.
func (s *Server) boxMoverReads(ctx context.Context, x *session, m store.EditableMessage, hum string) bool {
	if s.boxReadsCard(ctx, x, m) {
		return true
	}
	if hum == "" {
		return false
	}
	ok, err := s.canReadChannel(ctx, x.tenant, m.Channel, hum)
	return err == nil && ok
}

// boxMayMove is spec 041 §3.3 for an agent: it started the topic, or it acts
// for (typed_by, already verified bound) the tenant owner or an admin.
func (s *Server) boxMayMove(ctx context.Context, x *session, m store.EditableMessage, as, hum string) bool {
	if m.FromBox == x.box && m.FromID == as {
		return true
	}
	return hum != "" && s.mayChangeTopic(ctx, x.tenant, hum, "", "")
}

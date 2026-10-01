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

// A box agent adds, or removes, an emoji reaction on a message of a topic
// (CLE-77895, owner t1 b23639e2: "Do not archive this discussion. Leave it
// there for now but add an emoji for something on hold"). It is the box twin
// of the browser's PUT/DELETE /v1/messages/{msg_id}/reactions: the same
// glyph check (canonicalEmoji: a picker glyph or a status mark such as ⏸️),
// the same store write (AddReaction / RemoveReaction) and the same
// message_reaction frame to the open browsers. The target is react_msg, or
// the topic's opening card (store.TaskCard) when it is empty; with task_id
// set it must belong to that topic (task_id may be empty when react_msg is
// given), and it must pass the read door (the box sent, was addressed or was
// delivered it), else not_found. The actor is the acting agent, one this box
// announced. react_op list reads the target's reactions and writes nothing.

// onReact answers a react frame.
func (s *Server) onReact(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a react frame needs msg_id (a UUID) to pair the reply")
		return
	}
	out, ae := s.boxReact(ctx, x, f)
	if ae != nil {
		x.fail(ctx, id, ae.token, ae.status, ae.detail)
		return
	}
	raw, err := json.Marshal(out)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TReact, MsgID: id, TaskID: f.TaskID, ReactOp: f.ReactOp, Emoji: f.Emoji, Reaction: raw}) //nolint:errcheck
}

// boxReact checks the frame, resolves the target and writes the reaction.
func (s *Server) boxReact(ctx context.Context, x *session, f wire.Frame) (map[string]any, *issueErr) {
	task := f.TaskID
	if (task != "" || f.ReactMsg == "") && (!uuidRe.MatchString(task) || task != strings.ToLower(task)) {
		return nil, &issueErr{http.StatusBadRequest, "bad_frame", "a react frame needs task_id (the topic's lowercase UUID) or react_msg"}
	}
	if f.ReactMsg != "" && (!uuidRe.MatchString(f.ReactMsg) || f.ReactMsg != strings.ToLower(f.ReactMsg)) {
		return nil, &issueErr{http.StatusBadRequest, "bad_frame", "react_msg must be a lowercase message UUID"}
	}
	if f.ReactOp == "list" {
		return s.boxReactList(ctx, x, f)
	}
	if f.ReactOp != "add" && f.ReactOp != "remove" {
		return nil, &issueErr{http.StatusBadRequest, "bad_frame", "react_op must be add, remove or list"}
	}
	emoji := canonicalEmoji(f.Emoji)
	if emoji == "" {
		return nil, &issueErr{http.StatusBadRequest, "bad_emoji", "emoji must be one offered glyph"}
	}
	if detail := senderRefusal(x, f.As); detail != "" {
		return nil, &issueErr{http.StatusForbidden, TokenFromNotAnnounced, detail}
	}
	t, err := s.o.Store.GetTenant(ctx, x.tenant)
	if err != nil {
		return nil, &issueErr{http.StatusInternalServerError, "internal", "tenant unavailable"}
	}
	if !billing.AllowsWrite(t.BillingStatus) {
		return nil, &issueErr{billing.HTTPUnpaid, billing.TokenUnpaid, "tenant billing is unpaid"}
	}
	m, ae := s.reactTarget(ctx, x, task, f.ReactMsg)
	if ae != nil {
		return nil, ae
	}
	now := s.o.Now()
	if f.ReactOp == "add" {
		err = s.o.Store.AddReaction(ctx, x.tenant, m.MsgID, f.As, emoji, now)
	} else {
		err = s.o.Store.RemoveReaction(ctx, x.tenant, m.MsgID, f.As, emoji, now)
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		return nil, &issueErr{http.StatusNotFound, "not_found", "no such message"}
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", m.MsgID).Msg("box reaction store")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "emoji not stored"}
	}
	rows, err := s.o.Store.ReactionsFor(ctx, x.tenant, []string{m.MsgID})
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", m.MsgID).Msg("box reaction list")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "emoji not stored"}
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("msg_id", m.MsgID).Str("by", f.As).Str("op", f.ReactOp).Str("emoji", emoji).Msg("reaction by box")
	grouped := groupReactions(rows[m.MsgID])
	s.fanoutReaction(ctx, x.tenant, m, grouped)
	return map[string]any{"msg_id": m.MsgID, "task_id": m.TaskID, "reactions": grouped}, nil
}

// boxReactList is react_op list: the target's reactions, read-only (no
// emoji, no billing gate), behind the same target rule and read door, so an
// operator can verify a mark without writing (CLE-77895).
func (s *Server) boxReactList(ctx context.Context, x *session, f wire.Frame) (map[string]any, *issueErr) {
	if detail := senderRefusal(x, f.As); detail != "" {
		return nil, &issueErr{http.StatusForbidden, TokenFromNotAnnounced, detail}
	}
	m, ae := s.reactTarget(ctx, x, f.TaskID, f.ReactMsg)
	if ae != nil {
		return nil, ae
	}
	rows, err := s.o.Store.ReactionsFor(ctx, x.tenant, []string{m.MsgID})
	if err != nil {
		s.o.Log.Error().Err(err).Str("msg_id", m.MsgID).Msg("box reaction list")
		return nil, &issueErr{http.StatusInternalServerError, "internal", "reactions unavailable"}
	}
	return map[string]any{"msg_id": m.MsgID, "task_id": m.TaskID, "reactions": groupReactions(rows[m.MsgID])}, nil
}

// reactTarget is the message the reaction hangs on: msgID when given (a
// message of task, unless task is ""), else the task's opening card. A message this
// box cannot read answers as absent.
func (s *Server) reactTarget(ctx context.Context, x *session, task, msgID string) (store.EditableMessage, *issueErr) {
	absent := &issueErr{http.StatusNotFound, "not_found", "no such message in that topic"}
	now := s.o.Now()
	if msgID == "" {
		if s.o.LobbyTaskID != "" && task == s.o.LobbyTaskID {
			return store.EditableMessage{}, &issueErr{http.StatusConflict, "not_a_card", "the lobby is one task of many cards: name the message with react_msg"}
		}
		card, err := s.o.Store.TaskCard(ctx, x.tenant, task, now)
		if err != nil && !errors.Is(err, store.ErrNotFound) {
			s.o.Log.Error().Err(err).Str("task_id", task).Msg("box reaction card")
			return store.EditableMessage{}, &issueErr{http.StatusInternalServerError, "internal", "topic unavailable"}
		}
		if err != nil {
			return store.EditableMessage{}, absent
		}
		msgID = card.MsgID
	}
	m, err := s.o.Store.GetEditable(ctx, x.tenant, msgID, now)
	switch {
	case errors.Is(err, store.ErrNotFound):
		return m, absent
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", msgID).Msg("box reaction lookup")
		return m, &issueErr{http.StatusInternalServerError, "internal", "message unavailable"}
	}
	if (task != "" && m.TaskID != task) || !s.boxReadsCard(ctx, x, m) {
		return m, absent
	}
	return m, nil
}

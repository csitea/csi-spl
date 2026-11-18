// SPDX-License-Identifier: AGPL-3.0-only

package hub

import (
	"context"
	"errors"
	"net/http"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The "Move to workspace" confirm (spec 169 T15, section 8.5.5 items 1 and 2),
// on the member session in <SRC>'s host:
//
//	POST /v1/channels/{channel}/workspace-move  {dst, keep, keep_emails, leave_hours}
//
//   - The door is the plan's (channelMoveBrowserDoor, channelMoveBrowserRequest):
//     the session, the biz owner of the operator workspace, one of the person's
//     targets. The body takes no step and no mark: an unknown field is 400, so
//     the browser never drives P2 to P7 (C33).
//   - Nothing is written while the move is blocked (409 move_blocked with the
//     plan's .blocked), while this channel has an open journal in <DST> (409
//     move_open), or on a store with no journal (501).
//   - The click is the owner's GO (Q9 A): the hub writes, in a new topic of the
//     operator workspace's #lobby, a poll form naming <SRC>/<CHANNEL> and
//     <DST>, and the person's answer "Poll: <form>" / "Answer: GO — Go", both as
//     that person from box-wui. channelMoveGo then checks that answer like any
//     other (C32), so the check stays in one place.
//   - Then P1, with the answer's msg id as the journal's GO and the dialog's
//     detail kept in P1's step for P2 (p1). A box picks the move up (T16).
//   - One confirm of a channel runs at a time: the store's lock is taken
//     before the journal is read, and held until the answer; a click while
//     another confirm holds it is 409 move_open at once. A refusal after
//     the GO's posts (403 go_required, 409 move_refused, 500) deletes them, so
//     every GO left in the operator workspace is a journal's (R7 W1, W2).
//   - 200 {move_id, topic}: topic is the GO's task in the operator workspace,
//     where the move's status is posted (8.5.6, T17).

// Refusal tokens of the confirm.
const (
	tokenMoveBlocked = "move_blocked"
	tokenMoveOpen    = "move_open"
)

// channelMoveConfirmed is the confirm's answer.
type channelMoveConfirmed struct {
	MoveID string `json:"move_id"`
	Topic  string `json:"topic"`
}

// handleChannelMoveConfirm is POST /v1/channels/{channel}/workspace-move.
func (s *Server) handleChannelMoveConfirm(w http.ResponseWriter, r *http.Request) {
	src, hum, ch, ok := s.channelMoveBrowserDoor(w, r)
	if !ok {
		return
	}
	q, ok := s.channelMoveBrowserRequest(w, r, src, hum, ch)
	if !ok {
		return
	}
	jr, ok := s.channelMoveJournals(w)
	if !ok {
		return
	}
	unlock, err := jr.LockChannelMove(r.Context(), q.Dst, q.Src, q.Channel)
	if errors.Is(err, store.ErrConflict) {
		writeJSON(w, http.StatusConflict, map[string]any{"error": tokenMoveOpen, "detail": err.Error()})
		return
	}
	if err != nil {
		s.o.Log.Error().Err(err).Msg("browser.channel_move_confirm lock")
		writeErr(w, http.StatusInternalServerError, "internal", "the move's lock was not taken")
		return
	}
	defer unlock()
	if !s.channelMoveConfirmFree(w, r, jr, q) {
		return
	}
	a, ok := s.channelMoveBrowserBlocked(w, r, q)
	if !ok {
		return
	}
	if len(a.Blocked) > 0 {
		writeJSON(w, http.StatusConflict, map[string]any{"error": tokenMoveBlocked,
			"detail": "the move is blocked: clear every line of .blocked first", "blocked": a.Blocked})
		return
	}
	g, err := s.channelMoveGoPosts(r.Context(), hum, q)
	if err != nil {
		s.o.Log.Error().Err(err).Msg("browser.channel_move_confirm go")
		writeErr(w, http.StatusInternalServerError, "internal", "the GO was not stored")
		return
	}
	q.GoMsgID = &g.answer
	if why := s.channelMoveGoRefusal(r.Context(), q); why != "" {
		s.channelMoveGoWithdraw(r.Context(), g)
		writeErr(w, http.StatusForbidden, tokenGoRequired, why)
		return
	}
	run := &channelMoveRun{s: s, q: q, op: hum, jr: jr}
	if _, err := run.step(r.Context(), "P1"); err != nil {
		s.channelMoveGoWithdraw(r.Context(), g)
		s.channelMoveFail(w, run, "P1", err)
		return
	}
	s.o.Log.Info().Str("move_id", run.moveID()).Str("step", "P1").Msg("browser.channel_move_confirm")
	writeJSON(w, http.StatusOK, channelMoveConfirmed{MoveID: run.moveID(), Topic: g.topic})
}

// channelMoveConfirmFree refuses a second confirm while this channel's journal
// in <DST> is open: the GO is written once per move, and OpenChannelMove would
// refuse the second GO only after its posts were stored.
func (s *Server) channelMoveConfirmFree(w http.ResponseWriter, r *http.Request, jr store.ChannelMoveJournals, q channelMoveRequest) bool {
	j, err := jr.ChannelMoveJournal(r.Context(), q.Dst, q.Src, q.Channel)
	switch {
	case err != nil:
		s.o.Log.Error().Err(err).Msg("browser.channel_move_confirm journal")
		writeErr(w, http.StatusInternalServerError, "internal", "journal unavailable")
		return false
	case j != nil && !j.Done:
		writeJSON(w, http.StatusConflict, map[string]any{"error": tokenMoveOpen,
			"detail": "this channel's move is already confirmed: " + j.MoveID, "move_id": j.MoveID})
		return false
	}
	return true
}

// channelMoveGoPost is the GO's two posts in the operator workspace.
type channelMoveGoPost struct{ op, topic, form, answer string }

// channelMoveGoPosts writes the GO's form and the person's answer in a new
// topic of the operator workspace's #lobby. The form names both workspaces as
// whole slugs, the words channelMoveGo reads (8.1). A form whose answer was
// not stored is withdrawn.
func (s *Server) channelMoveGoPosts(ctx context.Context, hum string, q channelMoveRequest) (channelMoveGoPost, error) {
	op, err := s.operatorTenant(ctx)
	if err != nil {
		return channelMoveGoPost{}, err
	}
	if op == "" {
		return channelMoveGoPost{}, errors.New("no operator workspace")
	}
	g := channelMoveGoPost{op: op, topic: uid.New(), form: uid.New(), answer: uid.New()}
	what := q.Src + "/" + q.Channel + " to " + q.Dst
	form := "Move the channel " + what + "?\n\nThis cannot be undone once the rows have moved.\n\n" +
		"```poll\nMove " + what + "?\n(GO) Go\n```"
	if err := s.channelMovePersonPost(ctx, op, hum, g.topic, g.form, form, 1); err != nil {
		return channelMoveGoPost{}, err
	}
	if err := s.channelMovePersonPost(ctx, op, hum, g.topic, g.answer, "Poll: "+g.form+"\nAnswer: GO — Go", 0); err != nil {
		s.channelMoveGoWithdraw(ctx, channelMoveGoPost{op: op, form: g.form})
		return channelMoveGoPost{}, err
	}
	return g, nil
}

// channelMoveGoWithdraw deletes the GO's posts after a refusal, the answer
// first, and drops them from the browsers that were shown them: a refused
// confirm leaves no GO that a later move could use (R7 W2, N2). It runs
// even when the click's request is gone.
func (s *Server) channelMoveGoWithdraw(ctx context.Context, g channelMoveGoPost) {
	ctx = context.WithoutCancel(ctx)
	for _, id := range []string{g.answer, g.form} {
		if id == "" {
			continue
		}
		m, err := s.o.Store.GetEditable(ctx, g.op, id, s.o.Now())
		if err == nil {
			err = s.o.Store.DeleteMessage(ctx, g.op, id)
		}
		if err != nil {
			s.o.Log.Error().Err(err).Str("msg_id", id).Msg("browser.channel_move_confirm withdraw")
			continue
		}
		s.fanoutDeleted(ctx, g.op, m)
	}
}

// channelMovePersonPost stores one post of hum in tenant's #lobby, as a browser
// send with no agent fan-out stores it: from box-wui, the unsigned envelope.
func (s *Server) channelMovePersonPost(ctx context.Context, tenant, hum, task, id, body string, isParent int) error {
	m := &msg.Message{V: s.writeVersion(), MsgID: id, TaskID: task, TS: s.o.Now().UTC().Format(time.RFC3339),
		From: hum, To: BroadcastID, Kind: "note", Body: body, Files: []msg.Attachment{}}
	if err := m.Validate(); err != nil {
		return err
	}
	inner, err := msg.Canonical(m)
	if err != nil {
		return err
	}
	env := &wire.Envelope{FromBox: WUIBox, ToBox: WUIBox, Channel: store.ChannelLobby, Msg: inner}
	_, err = s.commitRow(ctx, tenant, env, m, isParent)
	return err
}

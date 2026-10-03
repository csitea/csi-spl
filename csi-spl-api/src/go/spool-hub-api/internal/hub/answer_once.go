package hub

import (
	"context"
	"errors"
	"fmt"
	"net/http"

	"github.com/csitea/csi-spl/spool-hub-api/internal/msg"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Answer once (spec 068 section 4.2, rdb 0111). A send frame that carries
// answers=<msg_id> (and if_gen, the responsible_gen its seat claimed the
// message on) is an agent's answer to that message. The hub stores it only
// when the sender's seat, <from>@<from_box>, is the message's responsible on
// that gen, and only once: a second answer is refused 409 naming the first.
// Hub metadata like typed_by: outside the signed envelope, never on a frame
// to a box.

// Answer-once refusal tokens.
const (
	TokenAnswered       = wire.TokenAnswered
	TokenNotResponsible = wire.TokenNotResponsible
)

// claimAnswer runs the guard for f; nil, nil when f answers nothing. On
// success undo releases the claim, for a post that is then not stored.
func (s *Server) claimAnswer(ctx context.Context, x *session, env *wire.Envelope, m *msg.Message, f wire.Frame) (rf *frameRefusal, undo func()) {
	if f.Answers == "" {
		return nil, nil
	}
	if !uuidRe.MatchString(f.Answers) || f.Answers == m.MsgID {
		return &frameRefusal{"bad_json", http.StatusBadRequest, "answers must be the msg_id of another message"}, nil
	}
	if f.IfGen < 0 {
		return &frameRefusal{"bad_json", http.StatusBadRequest, "if_gen must be >= 0"}, nil
	}
	ao, ok := s.o.Store.(store.AnswerOnce)
	if !ok {
		return &frameRefusal{"not_implemented", http.StatusNotImplemented, "this hub cannot guard answers"}, nil
	}
	seat := m.From + "@" + env.FromBox
	got, err := ao.ClaimAnswer(ctx, x.tenant, store.Answer{
		Answers: f.Answers, AnswerMsgID: m.MsgID, Seat: seat, Gen: f.IfGen, AnsweredAt: s.o.Now(),
	})
	switch {
	case errors.Is(err, store.ErrNotFound):
		return &frameRefusal{"not_found", http.StatusNotFound, "no such message " + f.Answers}, nil
	case errors.Is(err, store.ErrAnswered):
		return &frameRefusal{TokenAnswered, http.StatusConflict, fmt.Sprintf(
			"%s is already answered by %s from %s", f.Answers, got.AnswerMsgID, got.Seat)}, nil
	case errors.Is(err, store.ErrNotResponsible):
		holder := "nobody"
		if got.Seat != "" {
			holder = got.Seat
		}
		return &frameRefusal{TokenNotResponsible, http.StatusConflict, fmt.Sprintf(
			"%s is held by %s on gen %d, not by %s on gen %d", f.Answers, holder, got.Gen, seat, f.IfGen)}, nil
	case err != nil:
		s.o.Log.Error().Err(err).Str("msg_id", m.MsgID).Str("answers", f.Answers).Msg("claim answer")
		return &frameRefusal{"internal", http.StatusInternalServerError, "answer not recorded"}, nil
	}
	return nil, func() {
		if err := ao.ReleaseAnswer(context.WithoutCancel(ctx), x.tenant, f.Answers, m.MsgID); err != nil {
			s.o.Log.Error().Err(err).Str("msg_id", m.MsgID).Str("answers", f.Answers).Msg("release answer")
		}
	}
}

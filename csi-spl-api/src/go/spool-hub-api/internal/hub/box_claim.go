package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/agentid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The peer claim on a message (spec 068 4.1, rdb 0110, lane L1): a peer
// seat's poll loop (do_spl_peer_poll) and its agent (`spool claim`) lock,
// keep, give back and close messages through claim frames on a one-shot
// role=cli session:
//
//	claim_op poll     - close dead what ran out CLAIM_MAX times (returned once
//	                    as dead: tell the owner), then lock up to max free peer
//	                    messages for the seat for ttl_s, oldest first
//	claim_op renew    - extend the seat's locks; answers every message it holds
//	claim_op release  - give one back now, reason required; harness-refused:<step>
//	                    adds the seat's harness to not_by
//	claim_op done     - close one: answered | handed:<lane> | no-reply:<reason>;
//	                    gen > 0 is a compare-and-set on the fence
//
// The seat is <id>@<box> and must be on the box that dialled (the hello
// proved its key): a box claims only for its own seats. The harness is the
// seat id's kind (c- claude, g- grok, ...), never the client's word. Every
// time is the hub's clock. A refused release or close is 409 naming the
// responsible seat, the close it already had, or the fence it moved to.

// ClaimRow is one message on the wire, in a claim reply.
type ClaimRow struct {
	MsgID       string          `json:"msg_id"`
	TaskID      string          `json:"task_id"`
	Channel     string          `json:"channel,omitempty"`
	TS          string          `json:"ts"`
	From        string          `json:"from"`
	To          string          `json:"to"`
	Kind        string          `json:"kind"`
	Responsible string          `json:"responsible,omitempty"`
	LockedUntil string          `json:"locked_until,omitempty"`
	Gen         int64           `json:"gen"`
	ClaimN      int             `json:"claim_n"`
	HandledAt   string          `json:"handled_at,omitempty"`
	HandledHow  string          `json:"handled_how,omitempty"`
	NotBy       []string        `json:"not_by,omitempty"`
	Msg         json.RawMessage `json:"msg,omitempty"` // the v:1 message, on poll: the loop writes it to the inbox
}

// claimIn is a request's Claim object.
type claimIn struct {
	Seat   string `json:"seat"`
	Max    int    `json:"max"`
	TTLS   int    `json:"ttl_s"`
	MsgID  string `json:"msg_id"`
	Gen    int64  `json:"gen"`
	How    string `json:"how"`
	Reason string `json:"reason"`
}

// claimAnswer is the reply object.
type claimAnswer struct {
	Seat string     `json:"seat"`
	Msgs []ClaimRow `json:"msgs"`
	Dead []ClaimRow `json:"dead"`
}

func claimRow(m store.Message, withMsg bool) ClaimRow {
	r := ClaimRow{MsgID: m.MsgID, TaskID: m.TaskID, Channel: m.Channel, TS: askTime(m.TS),
		From: m.FromID + "@" + m.FromBox, To: m.ToID + "@" + m.ToBox, Kind: m.Kind, Responsible: m.Responsible,
		LockedUntil: askTime(m.LockedUntil), Gen: m.ResponsibleGen, ClaimN: m.ClaimN,
		HandledAt: askTime(m.HandledAt), HandledHow: m.HandledHow, NotBy: m.NotBy}
	if withMsg && json.Valid(m.Msg) {
		r.Msg = json.RawMessage(m.Msg)
	}
	return r
}

func claimRows(ms []store.Message, withMsg bool) []ClaimRow {
	out := make([]ClaimRow, 0, len(ms))
	for _, m := range ms {
		out = append(out, claimRow(m, withMsg))
	}
	return out
}

// onClaim answers a claim frame.
func (s *Server) onClaim(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a claim frame needs msg_id (a UUID) to pair the reply")
		return
	}
	out, ae := s.boxClaim(ctx, x, f)
	if ae != nil {
		x.fail(ctx, id, ae.token, ae.status, ae.detail)
		return
	}
	raw, err := json.Marshal(out)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TClaim, MsgID: id, ClaimOp: f.ClaimOp, Claim: raw}) //nolint:errcheck
}

// boxClaim checks the frame, resolves the seat and runs the op.
func (s *Server) boxClaim(ctx context.Context, x *session, f wire.Frame) (claimAnswer, *issueErr) {
	var in claimIn
	if err := json.Unmarshal(f.Claim, &in); err != nil {
		return claimAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "claim must be {seat, max, ttl_s, msg_id, gen, how, reason}"}
	}
	seat, ttl, ae := s.claimSeat(ctx, x, in)
	if ae != nil {
		return claimAnswer{}, ae
	}
	out := claimAnswer{Seat: seat, Msgs: []ClaimRow{}, Dead: []ClaimRow{}}
	switch f.ClaimOp {
	case "poll", "renew":
		return s.claimRead(ctx, x, f.ClaimOp, seat, in.Max, ttl, out)
	case "release", "done":
		return s.claimClose(ctx, x, f.ClaimOp, seat, in, out)
	}
	return claimAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "claim_op must be poll, renew, release or done"}
}

// claimSeat resolves the seat to <id>@<box> on the dialling box, and the lock TTL.
func (s *Server) claimSeat(ctx context.Context, x *session, in claimIn) (string, time.Duration, *issueErr) {
	seat, ae := s.resolveAgent(ctx, x.tenant, in.Seat, x.box)
	if ae != nil {
		return "", 0, ae
	}
	seat = store.AskAtBox(seat, x.box)
	if why := store.CheckClaimSeat(seat); why != "" {
		return "", 0, &issueErr{http.StatusBadRequest, "bad_frame", why}
	}
	if _, box := agentid.SplitAtBox(seat); box != x.box {
		return "", 0, &issueErr{http.StatusForbidden, "claim_seat_box", "box " + x.box + " may claim only for its own seats, not " + seat}
	}
	ttl := store.ClaimTTLDefault
	if in.TTLS != 0 {
		ttl = time.Duration(in.TTLS) * time.Second
		if ttl < store.ClaimTTLMin || ttl > store.ClaimTTLMax {
			return "", 0, &issueErr{http.StatusBadRequest, "bad_frame", "ttl_s must be 10..600"}
		}
	}
	return seat, ttl, nil
}

// claimRead runs a poll (lock new messages, close the dead) or a renew.
func (s *Server) claimRead(ctx context.Context, x *session, op, seat string, max int, ttl time.Duration, out claimAnswer) (claimAnswer, *issueErr) {
	now := s.o.Now()
	if op == "renew" {
		held, err := s.o.Store.RenewMessageClaims(ctx, x.tenant, seat, ttl, now)
		if err != nil {
			s.o.Log.Error().Err(err).Str("seat", seat).Msg("claim renew")
			return claimAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "claims unavailable"}
		}
		out.Msgs = claimRows(held, false)
		return out, nil
	}
	if max == 0 {
		max = 3
	}
	if max < 1 || max > store.ClaimPollMax {
		return claimAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "max must be 1..50"}
	}
	got, dead, err := s.o.Store.PollMessageClaims(ctx, x.tenant, store.ClaimPoll{Seat: seat, Harness: agentid.Kind(seat), Max: max, TTL: ttl}, now)
	if err != nil {
		s.o.Log.Error().Err(err).Str("seat", seat).Msg("claim poll")
		return claimAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "claims unavailable"}
	}
	if len(got)+len(dead) > 0 {
		s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("seat", seat).Int("claimed", len(got)).Int("dead", len(dead)).Msg("claim poll")
	}
	out.Msgs, out.Dead = claimRows(got, true), claimRows(dead, true)
	return out, nil
}

// claimClose runs a release (give it back) or a done (close it).
func (s *Server) claimClose(ctx context.Context, x *session, op, seat string, in claimIn, out claimAnswer) (claimAnswer, *issueErr) {
	if !uuidRe.MatchString(in.MsgID) {
		return claimAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "msg_id must be the claimed message's id (a UUID)"}
	}
	if in.Gen < 0 {
		return claimAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "gen must be the fence a poll returned (or 0)"}
	}
	c := store.ClaimClose{MsgID: in.MsgID, Seat: seat, Harness: agentid.Kind(seat), How: in.How, Reason: in.Reason, Gen: in.Gen}
	var m store.Message
	var err error
	if op == "release" {
		if why := store.CheckClaimReason(in.Reason); why != "" {
			return claimAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", why}
		}
		m, err = s.o.Store.ReleaseMessageClaim(ctx, x.tenant, c, s.o.Now())
	} else {
		if c.How == "" {
			c.How = "answered"
		}
		if why := store.CheckClaimHow(c.How); why != "" {
			return claimAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", why}
		}
		m, err = s.o.Store.CloseMessageClaim(ctx, x.tenant, c, s.o.Now())
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		return claimAnswer{}, &issueErr{http.StatusNotFound, "unknown_message", "no such message in this tenant"}
	case errors.Is(err, store.ErrNotPeerMessage):
		return claimAnswer{}, &issueErr{http.StatusConflict, "not_peer_message", "a message to one agent is " + m.Responsible + "'s alone: close it, do not release it"}
	case errors.Is(err, store.ErrConflict):
		return claimAnswer{}, &issueErr{http.StatusConflict, "claim_refused", claimRefusalDetail(m, c)}
	case err != nil:
		s.o.Log.Error().Err(err).Str("seat", seat).Str("msg", in.MsgID).Msg("claim " + op)
		return claimAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "claims unavailable"}
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("seat", seat).Str("msg", m.MsgID).
		Str("op", op).Str("how", m.HandledHow).Str("reason", in.Reason).Msg("claim " + op)
	out.Msgs = []ClaimRow{claimRow(m, false)}
	return out, nil
}

// claimRefusalDetail says why c lost: the message is closed, another seat
// (or nobody) holds it, or the fence moved.
func claimRefusalDetail(m store.Message, c store.ClaimClose) string {
	switch {
	case !m.HandledAt.IsZero():
		return "already closed " + m.HandledHow + " at " + askTime(m.HandledAt)
	case m.Responsible == "":
		return "nobody holds it: poll first"
	case m.Responsible != c.Seat:
		return "responsible is " + m.Responsible
	default:
		return "the fence moved: gen is " + strconv.FormatInt(m.ResponsibleGen, 10) + ", not " + strconv.FormatInt(c.Gen, 10)
	}
}

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
//	claim_op check    - the fence (4.2): held = the seat is still responsible
//	                    at gen, the message open and its lock live
//	claim_op adopt    - insert-if-absent (section 7, hub down): a free peer
//	                    message becomes the seat's as a claim makes it;
//	                    adopted false = another seat holds it, or it is closed
//
// The seat is <id>@<box> and must be on the box that dialled (the hello
// proved its key): a box claims only for its own seats. The harness is the
// seat id's kind (c- claude, g- grok, ...), never the client's word. Every
// time is the hub's clock. A refused release or close is 409 naming the
// responsible seat, the close it already had, or the fence it moved to.
//
// Spec 093 section 4 (task T009) adds the two-phase claim on the same frame:
//
//	claim_op poll + state idle|busy  - a ready seat's round poll (T1, T1j, and
//	                    the T3 / T5 / T10 it settles first): every open round
//	                    the seat is in comes back as a stub (no body), the dead
//	                    with theirs. Without state, poll stays 068's
//	claim_op accept   - the agent takes round n (T2): the first wins, gets the
//	                    body and the new fence; the loser is 409 claim_refused
//	claim_op park     - the holder waits on something outside itself (T6):
//	                    until (RFC 3339, or a duration on the hub clock), wait, reason
//	claim_op unpark   - parked -> owned (T7a)
//	claim_op reoffer  - parked -> a round for the holder alone (T7b, the poll loop)
//	claim_op touch    - the per-job touch (FR-007)
//	claim_op renew + fresh / able / anchor_age_s - T4 on the seat's heartbeat:
//	                    owned to anchor + 120 s while fresh, parked while able
//
// park, unpark, reoffer and touch need the holder at its fence (gen).

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
	Gen         int64           `json:"responsible_gen"`
	ClaimN      int             `json:"claim_n"`
	HandledAt   string          `json:"handled_at,omitempty"`
	HandledHow  string          `json:"handled_how,omitempty"`
	NotBy       []string        `json:"not_by,omitempty"`
	State       string          `json:"claim_state,omitempty"`
	Round       int             `json:"round,omitempty"` // offer_n: the number --accept --round names
	OfferUntil  string          `json:"offer_until,omitempty"`
	OfferSet    []string        `json:"offer_set,omitempty"`
	TouchedAt   string          `json:"touched_at,omitempty"`
	ParkedUntil string          `json:"parked_until,omitempty"`
	ParkReason  string          `json:"park_reason,omitempty"`
	WaitToken   string          `json:"wait_token,omitempty"`
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
	// spec 093
	State      string   `json:"state"` // poll: idle | busy; "" = 068's one-step poll
	Ready      []string `json:"ready"` // poll: the ready seats the loop knows
	Round      int      `json:"round"` // accept
	Until      string   `json:"until"` // park
	Wait       string   `json:"wait"`  // park
	Fresh      *bool    `json:"fresh"` // renew: set = 093's heartbeat renew
	Able       *bool    `json:"able"`
	AnchorAgeS *int     `json:"anchor_age_s"`
}

// hbRenew: the renew carries a heartbeat verdict (spec 093 T4).
func (in claimIn) hbRenew() bool { return in.Fresh != nil || in.Able != nil || in.AnchorAgeS != nil }

// claimAnswer is the reply object.
type claimAnswer struct {
	Seat    string     `json:"seat"`
	Msgs    []ClaimRow `json:"msgs"`
	Dead    []ClaimRow `json:"dead"`
	Held    bool       `json:"held,omitempty"`    // check
	Adopted bool       `json:"adopted,omitempty"` // adopt
}

func claimRow(m store.Message, withMsg bool) ClaimRow {
	r := ClaimRow{MsgID: m.MsgID, TaskID: m.TaskID, Channel: m.Channel, TS: askTime(m.TS),
		From: m.FromID + "@" + m.FromBox, To: m.ToID + "@" + m.ToBox, Kind: m.Kind, Responsible: m.Responsible,
		LockedUntil: askTime(m.LockedUntil), Gen: m.ResponsibleGen, ClaimN: m.ClaimN,
		HandledAt: askTime(m.HandledAt), HandledHow: m.HandledHow, NotBy: m.NotBy,
		State: claimState(m), Round: m.Round.OfferN, OfferUntil: askTime(m.Round.OfferUntil), OfferSet: m.Round.OfferSet,
		TouchedAt: askTime(m.Round.TouchedAt), ParkedUntil: askTime(m.Round.ParkedUntil), ParkReason: m.Round.ParkReason,
		WaitToken: m.Round.WaitToken}
	if withMsg && json.Valid(m.Msg) {
		r.Msg = json.RawMessage(m.Msg)
	}
	return r
}

// claimState is m's claim_state on the wire: a peer message from before
// rdb 0132 is free; a message to one agent has none.
func claimState(m store.Message) string {
	if m.Round.State == "" && m.NeedsPeer {
		return store.ClaimFree
	}
	return m.Round.State
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
		if in.State != "" || (f.ClaimOp == "renew" && in.hbRenew()) {
			return s.claimRound(ctx, x, f.ClaimOp, seat, in, out)
		}
		return s.claimRead(ctx, x, f.ClaimOp, seat, in.Max, ttl, out)
	case "accept", "park", "unpark", "reoffer", "touch":
		return s.claimAct(ctx, x, f.ClaimOp, seat, in, out)
	case "release", "done":
		return s.claimClose(ctx, x, f.ClaimOp, seat, in, out)
	case "check", "adopt":
		return s.claimOne(ctx, x, f.ClaimOp, seat, ttl, in, out)
	}
	return claimAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "claim_op must be poll, renew, accept, park, unpark, reoffer, touch, release, done, check or adopt"}
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

// claimOne runs a check (read the fence) or an adopt (take it if absent).
func (s *Server) claimOne(ctx context.Context, x *session, op, seat string, ttl time.Duration, in claimIn, out claimAnswer) (claimAnswer, *issueErr) {
	if !uuidRe.MatchString(in.MsgID) {
		return claimAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "msg_id must be the message's id (a UUID)"}
	}
	now := s.o.Now()
	var m store.Message
	var err error
	if op == "check" {
		if in.Gen < 1 {
			return claimAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "check needs gen, the fence the poll returned"}
		}
		m, err = s.o.Store.GetMessageClaim(ctx, x.tenant, in.MsgID)
		out.Held = err == nil && store.ClaimHeld(m, seat, in.Gen, now)
	} else {
		m, out.Adopted, err = s.o.Store.AdoptMessageClaim(ctx, x.tenant, store.ClaimClose{MsgID: in.MsgID, Seat: seat}, ttl, now)
	}
	switch {
	case errors.Is(err, store.ErrNotFound):
		return claimAnswer{}, &issueErr{http.StatusNotFound, "unknown_message", "no such message in this tenant"}
	case errors.Is(err, store.ErrNotPeerMessage):
		return claimAnswer{}, &issueErr{http.StatusConflict, "not_peer_message", "a message to one agent is " + m.Responsible + "'s alone"}
	case err != nil:
		s.o.Log.Error().Err(err).Str("seat", seat).Str("msg", in.MsgID).Msg("claim " + op)
		return claimAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "claims unavailable"}
	}
	if out.Adopted {
		s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("seat", seat).Str("msg", m.MsgID).Msg("claim adopt")
	}
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

// claimRound runs spec 093's round poll (state idle|busy) or heartbeat renew.
func (s *Server) claimRound(ctx context.Context, x *session, op, seat string, in claimIn, out claimAnswer) (claimAnswer, *issueErr) {
	now := s.o.Now()
	if op == "renew" {
		r, ae := roundRenewArgs(seat, in)
		if ae != nil {
			return claimAnswer{}, ae
		}
		held, err := s.o.Store.RenewMessageRounds(ctx, x.tenant, r, now)
		if err != nil {
			s.o.Log.Error().Err(err).Str("seat", seat).Msg("claim round renew")
			return claimAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "claims unavailable"}
		}
		out.Msgs = claimRows(held, false)
		return out, nil
	}
	p, ae := roundPollArgs(seat, x.box, in)
	if ae != nil {
		return claimAnswer{}, ae
	}
	offered, dead, err := s.o.Store.PollMessageRounds(ctx, x.tenant, p, now)
	if err != nil {
		s.o.Log.Error().Err(err).Str("seat", seat).Msg("claim round poll")
		return claimAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "claims unavailable"}
	}
	if len(dead) > 0 {
		s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("seat", seat).Int("rounds", len(offered)).Int("dead", len(dead)).Msg("claim round poll")
	}
	// a round's stub carries no body (spec 093 4.3): the accept returns it
	out.Msgs, out.Dead = claimRows(offered, false), claimRows(dead, true)
	return out, nil
}

// roundPollArgs checks a round poll: the state, max, and the ready seats
// (a bare id is the dialling box's; the polling seat always counts).
func roundPollArgs(seat, box string, in claimIn) (store.RoundPoll, *issueErr) {
	if in.State != "idle" && in.State != "busy" {
		return store.RoundPoll{}, &issueErr{http.StatusBadRequest, "bad_frame", "state must be idle or busy"}
	}
	if in.Max == 0 {
		in.Max = 3
	}
	if in.Max < 1 || in.Max > store.ClaimPollMax {
		return store.RoundPoll{}, &issueErr{http.StatusBadRequest, "bad_frame", "max must be 1..50"}
	}
	if len(in.Ready) > store.ClaimPollMax {
		return store.RoundPoll{}, &issueErr{http.StatusBadRequest, "bad_frame", "ready names at most 50 seats"}
	}
	ready := []string{seat}
	for _, r := range in.Ready {
		r = store.AskAtBox(r, box)
		if why := store.CheckClaimSeat(r); why != "" {
			return store.RoundPoll{}, &issueErr{http.StatusBadRequest, "bad_frame", "ready: " + why}
		}
		if r != seat {
			ready = append(ready, r)
		}
	}
	return store.RoundPoll{Seat: seat, Harness: agentid.Kind(seat), Busy: in.State == "busy", Ready: ready, Max: in.Max}, nil
}

// roundRenewArgs checks a heartbeat renew: a fresh seat names its anchor.
func roundRenewArgs(seat string, in claimIn) (store.ClaimRenew, *issueErr) {
	r := store.ClaimRenew{Seat: seat, Fresh: in.Fresh != nil && *in.Fresh, Able: in.Able != nil && *in.Able}
	r.Able = r.Able || r.Fresh
	if r.Fresh && in.AnchorAgeS == nil {
		return r, &issueErr{http.StatusBadRequest, "bad_frame", "a fresh renew needs anchor_age_s: the lock runs from the anchor, never from now"}
	}
	if in.AnchorAgeS != nil {
		if *in.AnchorAgeS < 0 || *in.AnchorAgeS > 86400 {
			return r, &issueErr{http.StatusBadRequest, "bad_frame", "anchor_age_s must be 0..86400"}
		}
		r.AnchorAge = time.Duration(*in.AnchorAgeS) * time.Second
	}
	return r, nil
}

// claimAct runs an agent's call on one job: accept (T2), park (T6), unpark
// (T7a), reoffer (T7b), touch.
func (s *Server) claimAct(ctx context.Context, x *session, op, seat string, in claimIn, out claimAnswer) (claimAnswer, *issueErr) {
	now := s.o.Now()
	a, ae := claimActArgs(op, seat, in, now)
	if ae != nil {
		return claimAnswer{}, ae
	}
	steps := map[string]func(context.Context, string, store.ClaimAct, time.Time) (store.Message, error){
		"accept": s.o.Store.AcceptMessageClaim, "park": s.o.Store.ParkMessageClaim, "unpark": s.o.Store.UnparkMessageClaim,
		"reoffer": s.o.Store.ReofferMessageClaim, "touch": s.o.Store.TouchMessageClaim,
	}
	m, err := steps[op](ctx, x.tenant, a, now)
	switch {
	case errors.Is(err, store.ErrNotFound):
		return claimAnswer{}, &issueErr{http.StatusNotFound, "unknown_message", "no such message in this tenant"}
	case errors.Is(err, store.ErrClaimArg):
		return claimAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", store.CheckClaimPark(a, now)}
	case errors.Is(err, store.ErrConflict):
		return claimAnswer{}, &issueErr{http.StatusConflict, "claim_refused", roundRefusalDetail(op, m, a)}
	case err != nil:
		s.o.Log.Error().Err(err).Str("seat", seat).Str("msg", a.MsgID).Msg("claim " + op)
		return claimAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "claims unavailable"}
	}
	if op != "touch" {
		s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("seat", seat).Str("msg", m.MsgID).
			Str("op", op).Int64("gen", m.ResponsibleGen).Str("wait", a.Wait).Msg("claim " + op)
	}
	out.Msgs = []ClaimRow{claimRow(m, op == "accept")}
	return out, nil
}

// claimActArgs checks one job call: the message id, round (accept) or the
// fence (the holder's calls), and a park's until / wait / reason.
func claimActArgs(op, seat string, in claimIn, now time.Time) (store.ClaimAct, *issueErr) {
	a := store.ClaimAct{MsgID: in.MsgID, Seat: seat, Round: in.Round, Gen: in.Gen, Wait: in.Wait, Reason: in.Reason}
	bad := func(why string) (store.ClaimAct, *issueErr) {
		return a, &issueErr{http.StatusBadRequest, "bad_frame", why}
	}
	switch {
	case !uuidRe.MatchString(in.MsgID):
		return bad("msg_id must be the job's message id (a UUID)")
	case op == "accept" && in.Round < 1:
		return bad("accept needs round, the round number of the stub")
	case op != "accept" && in.Gen < 1:
		return bad(op + " needs gen, the fence the accept returned")
	case op != "park":
		return a, nil
	}
	until, err := time.Parse(time.RFC3339, in.Until)
	if err != nil {
		d, derr := time.ParseDuration(in.Until)
		if derr != nil {
			return bad("until must be an RFC 3339 time or a duration such as 30m")
		}
		until = now.Add(d)
	}
	a.Until = until.UTC()
	if why := store.CheckClaimPark(a, now); why != "" {
		return bad(why)
	}
	return a, nil
}

// roundRefusalDetail says why a job call lost: closed, another seat holds
// it, the round moved or is not the seat's, the lock ran out, the fence
// moved, or the job is in a state the call does not act on.
func roundRefusalDetail(op string, m store.Message, a store.ClaimAct) string {
	st := claimState(m)
	switch {
	case !m.HandledAt.IsZero():
		return "already closed " + m.HandledHow + " at " + askTime(m.HandledAt)
	case m.Responsible != "" && m.Responsible != a.Seat:
		return "lost: responsible is " + m.Responsible
	case op == "accept" && st == store.ClaimOffered && m.Round.OfferN != a.Round:
		return "the round is " + strconv.Itoa(m.Round.OfferN) + ", not " + strconv.Itoa(a.Round)
	case op == "accept" && st == store.ClaimOffered:
		return "round " + strconv.Itoa(a.Round) + " is not offered to " + a.Seat
	case op == "accept":
		return "no open round (claim_state " + st + "): it lapsed or was taken, drop the stub"
	case m.Responsible == "":
		return "nobody holds it (claim_state " + st + "): the lock ran out"
	case m.ResponsibleGen != a.Gen:
		return "the fence moved: gen is " + strconv.FormatInt(m.ResponsibleGen, 10) + ", not " + strconv.FormatInt(a.Gen, 10)
	}
	return "claim_state is " + st + ": " + op + " does not act on it"
}

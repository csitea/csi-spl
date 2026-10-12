package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strconv"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Asks to the orchestrator (CLE-77929, owner bug t1 2f7996aa): a blocker,
// task or escalation sent to the fleet lease's orch holder is also recorded
// here, so it survives a busy inbox, a lost poke and the holder's death. Ask
// frames ride a one-shot role=cli session:
//
//	ask_op put      - record a new open ask (idempotent on ask_id, the msg_id
//	                  that carried it: a journal replay changes nothing)
//	ask_op list     - the fleet's open asks to a role, oldest first (all: + closed week)
//	ask_op ack      - in progress, by <ID>@<box>
//	ask_op done     - closed, reason optional
//	ask_op decline  - closed, reason required
//	ask_op raise    - the lease tick re-raised it (raised_n + 1)
//	ask_op escalate - the lease tick told the owner (once)
//	ask_op release  - the lease tick: the holder's acquisition lock expired,
//	                  acked -> open (acked_by stays: the last holder)
//	ask_op dead     - the lease tick: the delivery limit was reached, closed
//	                  as dead (Kafka's archived), reason required
//	ask_op queue    - a spawn request waits for room (rdb 0180): queued, with
//	                  its position; never raised or escalated. placement
//	                  "<vendor>:<slug>" is optional
//
// The OD pool's jobs, role od (spec 134 3.3-3.4, rdb 0183; nothing calls them
// before P3/P4, the lease keeps doing all OD work):
//
//	ask_op enqueue   - insert a job {ask_id, kind, from, topic, summary,
//	                   issue_key, dedupe_key, vendor_allow, needs, lease_s,
//	                   needs_owner}; 409 ask_duplicate names the open one
//	ask_op lock-next - {seat, vendor, harness, caps}: the hub locks the oldest
//	                   lockable job of od_pool.kinds for the seat (asks: [] =
//	                   none; dead: the rows dead-lettered on the way). There
//	                   is no lock of a named job: no judgement in the lock path
//	ask_op renew | done | decline | release - {ask_id, by, gen}: the holder
//	                   at its gen, else 409 ask_held; release {by, no ask_id}
//	                   frees every job of the seat (the supervisor's kill);
//	                   release {refuse: <harness>} adds it to not_by
//	ask_op reopen    - needs_owner -> open (a human answered)
//	ask_op pool      - read the od_pool row; {set: true, ...} writes it
//	ask_op list      - {role: od, free: true}: the jobs a seat could lock now
//
// The record states follow Kafka's share groups (KIP-932, CLE-77942); the
// lock timeout and the delivery limit are the tick's knobs, not the hub's.
// Closing a closed ask is 409 with the current row, so the second closer
// learns who closed it. The hub stamps every time with its own clock and
// answers age_s / quiet_s from it. Who may: any box pinned in the tenant (the
// hello proved its key); the writing box is recorded from the session.

// AskRow is one ask on the wire, in both directions.
type AskRow struct {
	AskID       string `json:"ask_id"`
	Role        string `json:"role"`
	Kind        string `json:"kind"`
	From        string `json:"from"`
	Topic       string `json:"topic"`
	Summary     string `json:"summary"`
	State       string `json:"state,omitempty"`
	DeadlineAt  string `json:"deadline_at,omitempty"`
	AckedBy     string `json:"acked_by,omitempty"`
	ClosedBy    string `json:"closed_by,omitempty"`
	Reason      string `json:"reason,omitempty"`
	RaisedN     int    `json:"raised_n"`
	RaisedAt    string `json:"raised_at,omitempty"`
	EscalatedAt string `json:"escalated_at,omitempty"`
	EnqueuedAt  string `json:"enqueued_at,omitempty"`
	Placement   string `json:"placement,omitempty"`
	Position    int    `json:"position,omitempty"`
	QueueLen    int    `json:"queue_len,omitempty"`
	WriterBox   string `json:"writer_box,omitempty"`
	// role od (rdb 0183)
	LockUntil   string   `json:"lock_until,omitempty"`
	LeaseS      int      `json:"lease_s,omitempty"`
	Gen         int64    `json:"gen,omitempty"`
	DedupeKey   string   `json:"dedupe_key,omitempty"`
	IssueKey    string   `json:"issue_key,omitempty"`
	VendorAllow string   `json:"vendor_allow,omitempty"`
	Needs       string   `json:"needs,omitempty"`
	NotBy       []string `json:"not_by,omitempty"`
	CreatedAt   string   `json:"created_at,omitempty"`
	UpdatedAt   string   `json:"updated_at,omitempty"`
	AgeS        int64    `json:"age_s"`
	QuietS      int64    `json:"quiet_s"`
}

// askUpdate is an update request's Ask object; List is a list request's.
type askUpdate struct {
	AskID     string `json:"ask_id"`
	By        string `json:"by"`
	Reason    string `json:"reason"`
	Placement string `json:"placement"`
	Role      string `json:"role"`
	All       bool   `json:"all"`
	Free      bool   `json:"free"`   // list, role od: only the jobs a seat could lock now
	Gen       int64  `json:"gen"`    // role od: the holder's fence
	Refuse    string `json:"refuse"` // role od release: the harness joins not_by
}

// odEnqueue is an enqueue request's Ask object.
type odEnqueue struct {
	AskRow
	NeedsOwner bool `json:"needs_owner"`
}

// odLockReq is a lock-next request's Ask object.
type odLockReq struct {
	Seat    string   `json:"seat"`
	Vendor  string   `json:"vendor"`
	Harness string   `json:"harness"`
	Caps    []string `json:"caps"`
}

// PoolRow is the od_pool row on the wire; a pool request with Set writes it.
type PoolRow struct {
	Set       bool     `json:"set,omitempty"`
	By        string   `json:"by,omitempty"`
	ClaudeN   *int     `json:"claude_n,omitempty"`
	GrokN     *int     `json:"grok_n,omitempty"`
	MinBoxes  *int     `json:"min_boxes,omitempty"`
	VendorOut *string  `json:"vendor_out,omitempty"`
	OutUntil  *string  `json:"out_until,omitempty"`
	Kinds     []string `json:"kinds"`
	UpdatedBy string   `json:"updated_by,omitempty"`
	WriterBox string   `json:"writer_box,omitempty"`
	UpdatedAt string   `json:"updated_at,omitempty"`
}

// askAnswer is the reply object.
type askAnswer struct {
	Fleet   string   `json:"fleet"`
	Created bool     `json:"created"`
	Asks    []AskRow `json:"asks"`
	Dead    []AskRow `json:"dead,omitempty"` // lock-next: the jobs it dead-lettered
	Pool    *PoolRow `json:"pool,omitempty"`
}

func askTime(t time.Time) string {
	if t.IsZero() {
		return ""
	}
	return t.UTC().Format(time.RFC3339)
}

func askRow(a store.FleetAsk) AskRow {
	return AskRow{AskID: a.AskID, Role: a.Role, Kind: a.Kind, From: a.From, Topic: a.Topic, Summary: a.Summary, State: a.State,
		DeadlineAt: askTime(a.DeadlineAt), AckedBy: a.AckedBy, ClosedBy: a.ClosedBy, Reason: a.Reason,
		RaisedN: a.RaisedN, RaisedAt: askTime(a.RaisedAt), EscalatedAt: askTime(a.EscalatedAt),
		EnqueuedAt: askTime(a.EnqueuedAt), Placement: a.Placement, Position: a.Position, QueueLen: a.QueueLen, WriterBox: a.WriterBox,
		LockUntil: askTime(a.LockUntil), LeaseS: a.LeaseS, Gen: a.Gen, DedupeKey: a.DedupeKey, IssueKey: a.IssueKey,
		VendorAllow: a.VendorAllow, Needs: a.Needs, NotBy: a.NotBy,
		CreatedAt: askTime(a.CreatedAt), UpdatedAt: askTime(a.UpdatedAt),
		AgeS: int64(a.Age.Seconds()), QuietS: int64(a.Quiet.Seconds())}
}

func askRows(as []store.FleetAsk) []AskRow {
	out := []AskRow{}
	for _, a := range as {
		out = append(out, askRow(a))
	}
	return out
}

func poolRow(p store.OdPool) *PoolRow {
	until := askTime(p.OutUntil)
	return &PoolRow{ClaudeN: &p.ClaudeN, GrokN: &p.GrokN, MinBoxes: &p.MinBoxes, VendorOut: &p.VendorOut, OutUntil: &until,
		Kinds: append([]string{}, p.Kinds...), UpdatedBy: p.UpdatedBy, WriterBox: p.WriterBox, UpdatedAt: askTime(p.UpdatedAt)}
}

// onAsk answers an ask frame.
func (s *Server) onAsk(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "an ask frame needs msg_id (a UUID) to pair the reply")
		return
	}
	out, ae := s.boxAsk(ctx, x, f)
	if ae != nil {
		x.fail(ctx, id, ae.token, ae.status, ae.detail)
		return
	}
	raw, err := json.Marshal(out)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TAsk, MsgID: id, AskOp: f.AskOp, Fleet: f.Fleet, Ask: raw}) //nolint:errcheck
}

// boxAsk checks the frame and records, updates or lists the asks.
func (s *Server) boxAsk(ctx context.Context, x *session, f wire.Frame) (askAnswer, *issueErr) {
	if !store.FleetNameRe.MatchString(f.Fleet) {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "fleet must be a lowercase slug ([a-z0-9-], up to 32)"}
	}
	switch f.AskOp {
	case "put":
		return s.askPut(ctx, x, f)
	case "list":
		return s.askList(ctx, x, f)
	case "enqueue":
		return s.askEnqueue(ctx, x, f)
	case "lock-next":
		return s.askLockNext(ctx, x, f)
	case "pool":
		return s.askPool(ctx, x, f)
	default:
		return s.askUpdate(ctx, x, f)
	}
}

func (s *Server) askPut(ctx context.Context, x *session, f wire.Frame) (askAnswer, *issueErr) {
	var in AskRow
	if err := json.Unmarshal(f.Ask, &in); err != nil {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "ask must be an ask object"}
	}
	if in.Role == "" {
		in.Role = "orch"
	}
	var ae *issueErr
	if in.From, ae = s.resolveAgent(ctx, x.tenant, in.From, ""); ae != nil {
		return askAnswer{}, ae
	}
	a := store.FleetAsk{Fleet: f.Fleet, AskID: in.AskID, Role: in.Role, Kind: in.Kind, From: in.From, Topic: in.Topic, Summary: in.Summary}
	if in.DeadlineAt != "" {
		t, err := time.Parse(time.RFC3339, in.DeadlineAt)
		if err != nil {
			return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "deadline_at must be RFC 3339"}
		}
		a.DeadlineAt = t.UTC()
	}
	if why := store.CheckFleetAsk(a); why != "" {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", why}
	}
	got, created, err := s.o.Store.PutFleetAsk(ctx, x.tenant, a, x.box, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Str("ask", a.AskID).Msg("fleet ask put")
		return askAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "asks unavailable"}
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("fleet", f.Fleet).Str("ask", got.AskID).
		Str("kind", got.Kind).Str("from", got.From).Bool("created", created).Msg("fleet ask put")
	return askAnswer{Fleet: f.Fleet, Created: created, Asks: []AskRow{askRow(got)}}, nil
}

func (s *Server) askList(ctx context.Context, x *session, f wire.Frame) (askAnswer, *issueErr) {
	var in askUpdate
	if len(f.Ask) > 0 {
		if err := json.Unmarshal(f.Ask, &in); err != nil {
			return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "ask must be {role, all} for a list"}
		}
	}
	if in.Role != "" && !store.FleetNameRe.MatchString(in.Role) {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "role must be a lowercase slug"}
	}
	if in.Free && in.Role != store.OdRole {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "free lists role od only"}
	}
	as, err := s.o.Store.ListFleetAsks(ctx, x.tenant, f.Fleet, in.Role, in.All, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Msg("fleet ask list")
		return askAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "asks unavailable"}
	}
	out := askAnswer{Fleet: f.Fleet, Asks: []AskRow{}}
	now := s.o.Now()
	for _, a := range as {
		if !in.Free || store.OdFree(a, now) {
			out.Asks = append(out.Asks, askRow(a))
		}
	}
	return out, nil
}

func (s *Server) askUpdate(ctx context.Context, x *session, f wire.Frame) (askAnswer, *issueErr) {
	var in askUpdate
	if err := json.Unmarshal(f.Ask, &in); err != nil {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "ask must be {ask_id, by, reason}"}
	}
	var ae *issueErr
	if in.By, ae = s.resolveAgent(ctx, x.tenant, in.By, ""); ae != nil {
		return askAnswer{}, ae
	}
	if f.AskOp == store.AskRelease && in.AskID == "" {
		return s.askReleaseSeat(ctx, x, f, in.By)
	}
	if in.Refuse != "" && (f.AskOp != store.AskRelease || !store.OdVendorRe.MatchString(in.Refuse)) {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "refuse is a release's harness name (claude, grok, vibe)"}
	}
	if why := store.CheckFleetAskOp(f.AskOp, in.By, in.Reason); why != "" {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", why}
	}
	if !store.AskIDRe.MatchString(in.AskID) {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "ask_id must be a lowercase UUID"}
	}
	if !store.AskPlacementRe.MatchString(in.Placement) {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "placement must be <vendor>:<slug> (lowercase)"}
	}
	u := store.AskUpdate{Fleet: f.Fleet, AskID: in.AskID, Op: f.AskOp, By: in.By, Reason: in.Reason, Placement: in.Placement,
		Gen: in.Gen, Refuse: in.Refuse}
	got, err := s.o.Store.UpdateFleetAsk(ctx, x.tenant, u, x.box, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		return askAnswer{}, &issueErr{http.StatusNotFound, "unknown_ask", "no such ask in this fleet"}
	case errors.Is(err, store.ErrConflict):
		return askAnswer{}, &issueErr{http.StatusConflict, "ask_closed",
			"already " + got.State + " by " + got.ClosedBy + ": " + got.Reason}
	case errors.Is(err, store.ErrAskHeld):
		return askAnswer{}, &issueErr{http.StatusConflict, "ask_held", askHeldDetail(got)}
	case errors.Is(err, store.ErrAskRole):
		return askAnswer{}, &issueErr{http.StatusConflict, "ask_op_refused",
			f.AskOp + " does not apply to a role " + got.Role + " ask in state " + got.State}
	case err != nil:
		s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Str("ask", in.AskID).Msg("fleet ask update")
		return askAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "asks unavailable"}
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("fleet", f.Fleet).Str("ask", got.AskID).
		Str("op", f.AskOp).Str("by", in.By).Str("state", got.State).Msg("fleet ask update")
	if got.State == "queued" {
		got = s.askQueuePosition(ctx, x.tenant, f.Fleet, got)
	}
	return askAnswer{Fleet: f.Fleet, Asks: []AskRow{askRow(got)}}, nil
}

// askEnqueue inserts an od job (spec 134 3.5: code inserts rows).
func (s *Server) askEnqueue(ctx context.Context, x *session, f wire.Frame) (askAnswer, *issueErr) {
	var in odEnqueue
	if err := json.Unmarshal(f.Ask, &in); err != nil {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "ask must be an od job object"}
	}
	var ae *issueErr
	if in.From, ae = s.resolveAgent(ctx, x.tenant, in.From, ""); ae != nil {
		return askAnswer{}, ae
	}
	a := store.FleetAsk{Fleet: f.Fleet, AskID: in.AskID, Kind: in.Kind, From: in.From, Topic: in.Topic, Summary: in.Summary,
		IssueKey: in.IssueKey, DedupeKey: in.DedupeKey, VendorAllow: in.VendorAllow, Needs: in.Needs, LeaseS: in.LeaseS}
	if in.DeadlineAt != "" {
		t, err := time.Parse(time.RFC3339, in.DeadlineAt)
		if err != nil {
			return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "deadline_at must be RFC 3339"}
		}
		a.DeadlineAt = t.UTC()
	}
	if why := store.CheckOdJob(a); why != "" {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", why}
	}
	got, created, err := s.o.Store.EnqueueOdJob(ctx, x.tenant, a, in.NeedsOwner, x.box, s.o.Now())
	switch {
	case errors.Is(err, store.ErrAskDuplicate):
		return askAnswer{}, &issueErr{http.StatusConflict, "ask_duplicate",
			"an open " + got.Kind + " job holds dedupe_key " + got.DedupeKey + ": " + got.AskID + " (" + got.State + ")"}
	case err != nil:
		s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Str("ask", a.AskID).Msg("od job enqueue")
		return askAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "asks unavailable"}
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("fleet", f.Fleet).Str("ask", got.AskID).
		Str("kind", got.Kind).Str("state", got.State).Bool("created", created).Msg("od job enqueue")
	return askAnswer{Fleet: f.Fleet, Created: created, Asks: []AskRow{askRow(got)}}, nil
}

// askLockNext locks the next job for a seat. The box cap is the session's
// box, never the caller's word.
func (s *Server) askLockNext(ctx context.Context, x *session, f wire.Frame) (askAnswer, *issueErr) {
	var in odLockReq
	if err := json.Unmarshal(f.Ask, &in); err != nil {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "ask must be {seat, vendor, harness, caps}"}
	}
	var ae *issueErr
	if in.Seat, ae = s.resolveAgent(ctx, x.tenant, in.Seat, ""); ae != nil {
		return askAnswer{}, ae
	}
	q := store.OdLock{Fleet: f.Fleet, Seat: in.Seat, Vendor: in.Vendor, Harness: in.Harness, Caps: in.Caps}
	if why := store.CheckOdLock(q); why != "" {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", why}
	}
	got, ok, dead, err := s.o.Store.LockNextOdJob(ctx, x.tenant, q, x.box, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Str("seat", q.Seat).Msg("od lock-next")
		return askAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "asks unavailable"}
	}
	out := askAnswer{Fleet: f.Fleet, Asks: []AskRow{}}
	if len(dead) > 0 {
		out.Dead = askRows(dead)
	}
	if ok {
		out.Asks = append(out.Asks, askRow(got))
		s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("fleet", f.Fleet).Str("ask", got.AskID).
			Str("seat", got.AckedBy).Int64("gen", got.Gen).Int("lost", got.RaisedN).Msg("od lock-next")
	}
	return out, nil
}

// askReleaseSeat frees every job a seat holds (spec 134 3.3, release on kill).
func (s *Server) askReleaseSeat(ctx context.Context, x *session, f wire.Frame, seat string) (askAnswer, *issueErr) {
	if !store.ValidAskAgent(seat) || seat == "" {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "by must be the seat, <ID>@<box>"}
	}
	as, err := s.o.Store.ReleaseOdSeat(ctx, x.tenant, f.Fleet, seat, x.box, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Str("seat", seat).Msg("od release seat")
		return askAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "asks unavailable"}
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("fleet", f.Fleet).Str("seat", seat).
		Int("released", len(as)).Msg("od release seat")
	return askAnswer{Fleet: f.Fleet, Asks: askRows(as)}, nil
}

// askPool reads the od_pool row, or with set merges the given fields into it.
func (s *Server) askPool(ctx context.Context, x *session, f wire.Frame) (askAnswer, *issueErr) {
	var in PoolRow
	if len(f.Ask) > 0 {
		if err := json.Unmarshal(f.Ask, &in); err != nil {
			return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "ask must be a pool object"}
		}
	}
	p, err := s.o.Store.GetOdPool(ctx, x.tenant, f.Fleet)
	if err != nil {
		s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Msg("od pool get")
		return askAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "asks unavailable"}
	}
	if !in.Set {
		return askAnswer{Fleet: f.Fleet, Asks: []AskRow{}, Pool: poolRow(p)}, nil
	}
	var ae *issueErr
	if in.By, ae = s.resolveAgent(ctx, x.tenant, in.By, ""); ae != nil {
		return askAnswer{}, ae
	}
	if !store.ValidAskAgent(in.By) || in.By == "" {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "by must be the writer, <ID>@<box>"}
	}
	if ae := mergePool(&p, in); ae != nil {
		return askAnswer{}, ae
	}
	if why := store.CheckOdPool(p); why != "" {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", why}
	}
	if p, err = s.o.Store.PutOdPool(ctx, x.tenant, p, in.By, x.box, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Msg("od pool put")
		return askAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "asks unavailable"}
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("fleet", f.Fleet).Str("by", in.By).
		Strs("kinds", p.Kinds).Int("claude_n", p.ClaudeN).Int("grok_n", p.GrokN).Msg("od pool put")
	return askAnswer{Fleet: f.Fleet, Asks: []AskRow{}, Pool: poolRow(p)}, nil
}

// mergePool sets the fields a pool write names; the rest keep their value.
func mergePool(p *store.OdPool, in PoolRow) *issueErr {
	for _, kv := range []struct {
		src *int
		dst *int
	}{{in.ClaudeN, &p.ClaudeN}, {in.GrokN, &p.GrokN}, {in.MinBoxes, &p.MinBoxes}} {
		if kv.src != nil {
			*kv.dst = *kv.src
		}
	}
	if in.VendorOut != nil {
		p.VendorOut = *in.VendorOut
	}
	if in.OutUntil != nil {
		p.OutUntil = time.Time{}
		if *in.OutUntil != "" {
			t, err := time.Parse(time.RFC3339, *in.OutUntil)
			if err != nil {
				return &issueErr{http.StatusBadRequest, "bad_frame", "out_until must be RFC 3339 or empty"}
			}
			p.OutUntil = t.UTC()
		}
	}
	if in.Kinds != nil {
		p.Kinds = in.Kinds
	}
	return nil
}

// askHeldDetail names who holds the lock (spec 134 3.3: a second ack, or an
// od op off the holder's gen, is 409 naming the holder).
func askHeldDetail(a store.FleetAsk) string {
	if a.State != "acked" {
		return "not locked (" + a.State + "): the lock was lost"
	}
	d := "held by " + a.AckedBy
	if a.Role == store.OdRole {
		d += " at gen " + strconv.FormatInt(a.Gen, 10)
	}
	return d
}

// askQueuePosition fills a queued ask's position from its role's list, so
// the enqueue answer can say "position N of M" (best effort: 0 when the
// list fails, the row itself is already stored).
func (s *Server) askQueuePosition(ctx context.Context, tenant, fleet string, a store.FleetAsk) store.FleetAsk {
	as, err := s.o.Store.ListFleetAsks(ctx, tenant, fleet, a.Role, false, s.o.Now())
	if err != nil {
		return a
	}
	for _, q := range as {
		if q.AskID == a.AskID {
			a.Position, a.QueueLen = q.Position, q.QueueLen
		}
	}
	return a
}

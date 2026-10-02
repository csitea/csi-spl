package hub

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
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
	WriterBox   string `json:"writer_box,omitempty"`
	CreatedAt   string `json:"created_at,omitempty"`
	UpdatedAt   string `json:"updated_at,omitempty"`
	AgeS        int64  `json:"age_s"`
	QuietS      int64  `json:"quiet_s"`
}

// askUpdate is an update request's Ask object; List is a list request's.
type askUpdate struct {
	AskID  string `json:"ask_id"`
	By     string `json:"by"`
	Reason string `json:"reason"`
	Role   string `json:"role"`
	All    bool   `json:"all"`
}

// askAnswer is the reply object.
type askAnswer struct {
	Fleet   string   `json:"fleet"`
	Created bool     `json:"created"`
	Asks    []AskRow `json:"asks"`
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
		RaisedN: a.RaisedN, RaisedAt: askTime(a.RaisedAt), EscalatedAt: askTime(a.EscalatedAt), WriterBox: a.WriterBox,
		CreatedAt: askTime(a.CreatedAt), UpdatedAt: askTime(a.UpdatedAt),
		AgeS: int64(a.Age.Seconds()), QuietS: int64(a.Quiet.Seconds())}
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
	as, err := s.o.Store.ListFleetAsks(ctx, x.tenant, f.Fleet, in.Role, in.All, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Msg("fleet ask list")
		return askAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "asks unavailable"}
	}
	out := askAnswer{Fleet: f.Fleet, Asks: []AskRow{}}
	for _, a := range as {
		out.Asks = append(out.Asks, askRow(a))
	}
	return out, nil
}

func (s *Server) askUpdate(ctx context.Context, x *session, f wire.Frame) (askAnswer, *issueErr) {
	var in askUpdate
	if err := json.Unmarshal(f.Ask, &in); err != nil {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "ask must be {ask_id, by, reason}"}
	}
	if why := store.CheckFleetAskOp(f.AskOp, in.By, in.Reason); why != "" {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", why}
	}
	if !store.AskIDRe.MatchString(in.AskID) {
		return askAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "ask_id must be a lowercase UUID"}
	}
	got, err := s.o.Store.UpdateFleetAsk(ctx, x.tenant, store.AskUpdate{Fleet: f.Fleet, AskID: in.AskID, Op: f.AskOp, By: in.By, Reason: in.Reason}, x.box, s.o.Now())
	switch {
	case errors.Is(err, store.ErrNotFound):
		return askAnswer{}, &issueErr{http.StatusNotFound, "unknown_ask", "no such ask in this fleet"}
	case errors.Is(err, store.ErrConflict):
		return askAnswer{}, &issueErr{http.StatusConflict, "ask_closed",
			"already " + got.State + " by " + got.ClosedBy + ": " + got.Reason}
	case err != nil:
		s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Str("ask", in.AskID).Msg("fleet ask update")
		return askAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "asks unavailable"}
	}
	s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("fleet", f.Fleet).Str("ask", got.AskID).
		Str("op", f.AskOp).Str("by", in.By).Str("state", got.State).Msg("fleet ask update")
	return askAnswer{Fleet: f.Fleet, Asks: []AskRow{askRow(got)}}, nil
}

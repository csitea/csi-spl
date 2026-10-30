package hub

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The fleet-wide lease (CLE-77911, owner decision "a", t1 5fe56859): exactly
// one orchestrator and one master dispatcher act at a time across every
// machine of a fleet. Each machine's lease loop (do_spl_dispatch_lease
// LEASE_CMD=fleet) sends lease frames over a one-shot role=cli session:
//
//	lease_op get - read (fleet, lease_role)
//	lease_op cas - write holder only while the row's gen is still if_gen
//	               (0 = no row yet); a lost race is NOT an error: the answer
//	               carries won=false and the current row, so the loop decides
//	               again without a second read
//
// The hub stamps renewed_at with its own clock and answers age_s from it, so
// the machines' clocks never have to agree. Who may: any box pinned in the
// tenant (the hello proved its key); the writing box is recorded from the
// session, never from the frame. Which holder wins is the loops' rule
// (priority list, silence threshold); the hub only makes the write atomic.
//
// A cas may name why the loop moves the row (lease_reason, spec 162 3.3). A
// won cas with a reason that changes the holder writes one System log row,
// lease.<reason>; the hub never guesses a reason, so a cas without one (an
// old CLI, the tenant mirror) and a renew by the same holder log nothing.

// leaseAnswer is the reply object.
type leaseAnswer struct {
	Fleet  string `json:"fleet"`
	Role   string `json:"role"`
	Holder string `json:"holder"`
	Box    string `json:"box"`
	Gen    int64  `json:"gen"`
	AgeS   int64  `json:"age_s"` // -1 when there is no row
	Won    bool   `json:"won"`
}

// onLease answers a lease frame.
func (s *Server) onLease(ctx context.Context, x *session, f wire.Frame) {
	id := f.MsgID
	if !uuidRe.MatchString(id) {
		x.fail(ctx, "", "bad_frame", http.StatusBadRequest, "a lease frame needs msg_id (a UUID) to pair the reply")
		return
	}
	out, ae := s.boxLease(ctx, x, f)
	if ae != nil {
		x.fail(ctx, id, ae.token, ae.status, ae.detail)
		return
	}
	raw, err := json.Marshal(out)
	if err != nil {
		x.fail(ctx, id, "internal", http.StatusInternalServerError, "reply does not encode")
		return
	}
	x.write(ctx, wire.Frame{Type: wire.TLease, MsgID: id, LeaseOp: f.LeaseOp, Fleet: f.Fleet, LeaseRole: f.LeaseRole, Lease: raw}) //nolint:errcheck
}

// boxLease checks the frame and reads or compare-and-sets the row.
func (s *Server) boxLease(ctx context.Context, x *session, f wire.Frame) (leaseAnswer, *issueErr) {
	if !store.FleetNameRe.MatchString(f.Fleet) || !store.FleetNameRe.MatchString(f.LeaseRole) {
		return leaseAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "fleet and lease_role must be lowercase slugs ([a-z0-9-], up to 32)"}
	}
	now := s.o.Now()
	var (
		l   store.FleetLease
		err error
		won bool
	)
	switch f.LeaseOp {
	case "get":
		l, err = s.o.Store.GetFleetLease(ctx, x.tenant, f.Fleet, f.LeaseRole, now)
	case "cas":
		holder, ae := s.resolveAgent(ctx, x.tenant, f.Holder, "")
		if ae != nil {
			return leaseAnswer{}, ae
		}
		f.Holder = holder
		if !store.ValidFleetHolder(f.Holder) {
			return leaseAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "holder must be <agent id>@<box>"}
		}
		if f.IfGen < 0 {
			return leaseAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "if_gen must be the gen read (0 = no row yet)"}
		}
		if !wire.ValidLeaseReason(f.LeaseReason) {
			return leaseAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "lease_reason must be one of " + strings.Join(wire.LeaseReasons, ", ")}
		}
		l, err = s.o.Store.CASFleetLease(ctx, x.tenant, f.Fleet, f.LeaseRole, f.Holder, x.box, f.IfGen, now)
		won = err == nil
		if errors.Is(err, store.ErrConflict) {
			err = nil
		}
	default:
		return leaseAnswer{}, &issueErr{http.StatusBadRequest, "bad_frame", "lease_op must be get or cas"}
	}
	if err != nil {
		s.o.Log.Error().Err(err).Str("fleet", f.Fleet).Str("role", f.LeaseRole).Msg("fleet lease store")
		return leaseAnswer{}, &issueErr{http.StatusInternalServerError, "internal", "lease unavailable"}
	}
	age := int64(-1)
	if l.Gen > 0 {
		age = int64(l.Age.Seconds())
	}
	if f.LeaseOp == "cas" {
		s.o.Log.Info().Str("tenant", x.tenant).Str("box", x.box).Str("fleet", f.Fleet).Str("role", f.LeaseRole).
			Str("holder", l.Holder).Int64("gen", l.Gen).Bool("won", won).Str("reason", f.LeaseReason).Msg("fleet lease cas")
		if won {
			s.logLeaseHandover(ctx, f.LeaseReason, l)
		}
	}
	return leaseAnswer{Fleet: l.Fleet, Role: l.Role, Holder: l.Holder, Box: l.Box, Gen: l.Gen, AgeS: age, Won: won}, nil
}

// leaseHandoverEvent is the System log row of a won cas (spec 162 3.3), and
// false when it logs nothing: no reason named, or the holder did not change.
func leaseHandoverEvent(reason string, l store.FleetLease) (store.LogEvent, bool) {
	if reason == "" || l.PrevHolder == l.Holder {
		return store.LogEvent{}, false
	}
	level := store.LogLevelInfo
	if reason == "failover" || reason == "limit" {
		level = store.LogLevelWarn
	}
	msg := fmt.Sprintf("%s: %s -> %s (%s, silent %ds)", l.Role, l.PrevHolder, l.Holder, reason, int64(l.PrevAge.Seconds()))
	if l.PrevHolder == "" {
		msg = fmt.Sprintf("%s: none -> %s (%s)", l.Role, l.Holder, reason)
	}
	return store.LogEvent{Kind: "lease." + reason, Level: level, Actor: l.Holder, Message: msg,
		OriginKind: store.LogOriginComponent, OriginRef: "lease/" + l.Fleet + "/" + l.Role}, true
}

// logLeaseHandover writes leaseHandoverEvent's row, best effort: a failed
// log write is logged and the lease write stands.
func (s *Server) logLeaseHandover(ctx context.Context, reason string, l store.FleetLease) {
	e, ok := leaseHandoverEvent(reason, l)
	if !ok {
		return
	}
	es, ok := s.o.Store.(store.LogEvents)
	if !ok {
		return
	}
	if _, err := es.AddSystemEvent(ctx, e, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("kind", e.Kind).Msg("system event not written")
	}
}

// LogHubStarted writes the System log row hub.started, actor hub, message the
// version /version answers (spec 162 3.3): once per process start, so each
// deploy roll shows in the log. Best effort, like logLeaseHandover.
func (s *Server) LogHubStarted(ctx context.Context) {
	es, ok := s.o.Store.(store.LogEvents)
	if !ok {
		return
	}
	e := store.LogEvent{Kind: store.LogKindHubStarted, Actor: "hub", Message: s.o.Version,
		OriginKind: store.LogOriginComponent, OriginRef: "hub"}
	if _, err := es.AddSystemEvent(ctx, e, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Msg("hub.started not written")
	}
}

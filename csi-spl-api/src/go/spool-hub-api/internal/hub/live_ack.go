package hub

import (
	"context"
	"slices"
	"time"

	"github.com/google/uuid"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Live delivery (spec 053, rdb 0186). A box whose hello carries
// wire.FeatureLiveAck sends one ack frame per (recv, agent) with what the
// poke did: shown in a live pane, or a nack (no live window, refused, the
// agent exited). S1 records it (onAck). S3 (escalateNacked) hands a human
// post that was nacked and that no agent acked shown to the tenant's
// responder at the next relay tick, through the SPL-1225 escalate path and
// its once-only claim, instead of waiting for the 120 s reply timeout, which
// stays the backstop for every box that does not ack.

// nackSettle is how long a nack waits before it escalates, so the shown ack
// of another agent of the same recv (the box pokes them one by one) lands
// first and stands the escalation down.
const nackSettle = 3 * time.Second

// liveAcks is the store's live-ack support for this session, or nil when the
// box does not ack (or the store cannot keep it).
func (s *Server) liveAcks(x *session) store.LiveAcks {
	a, ok := s.o.Store.(store.LiveAcks)
	if !ok || x.role != wire.RoleBox || !x.has(wire.FeatureLiveAck) {
		return nil
	}
	return a
}

// onAck records one ack frame. Fire and forget: no reply. A frame for an
// agent this box did not announce, an unknown outcome, or a message the hub
// never sent this box changes nothing.
func (s *Server) onAck(ctx context.Context, x *session, f wire.Frame) {
	a := s.liveAcks(x)
	if a == nil {
		return
	}
	if _, err := uuid.Parse(f.MsgID); err != nil || !slices.Contains(wire.AckOutcomes, f.Outcome) {
		return
	}
	if !slices.Contains(x.agents, f.Agent) {
		return
	}
	rec := store.LiveAck{TenantID: x.tenant, MsgID: f.MsgID, Agent: f.Agent, Box: x.box, Outcome: f.Outcome, AckedAt: s.o.Now()}
	if _, err := a.RecordLiveAck(ctx, rec); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("box", x.box).Str("msg_id", f.MsgID).Msg("live ack")
	}
}

// escalateNacked is S3: every relay tick, the nacked human posts of the
// tenants this process holds boxes of go to the responder, claimed once.
func (s *Server) escalateNacked(ctx context.Context, tenants []string, now time.Time) {
	la, ok := s.o.Store.(store.LiveAcks)
	if !ok {
		return
	}
	for _, tenant := range tenants {
		posts, err := retryRead(func() ([]store.Queued, error) {
			return la.NackedPosts(ctx, tenant, now.Add(-relaySweepWindow), now.Add(-nackSettle), relaySweepMax)
		})
		if err != nil {
			s.relayDue.loops.fail(&s.o.Log, "relay nacked posts", tenant, "", err)
			continue
		}
		s.relayDue.loops.ok(&s.o.Log, "relay nacked posts", tenant, "")
		for _, p := range posts {
			env, err := wire.ParseEnvelope(p.Env)
			if err != nil {
				continue
			}
			m, err := env.Inner()
			if err != nil {
				continue
			}
			s.fallbackPost(ctx, tenant, s.storedChannel(ctx, tenant, env, m), env, m, escalation{swept: true, escalate: true, taskID: p.TaskID})
		}
	}
}

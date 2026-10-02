package hub

import (
	"context"
	"time"

	"github.com/google/uuid"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// The box's commit (spec 059 §11 S2, rdb 0100). A box whose hello carries
// wire.FeatureCommit sends a commit frame once a recv frame's inbox copy is
// written; until then its delivery stays sent-but-unacked, and goes to the
// box again at its next hello and, on a live socket, after ackTimeout (the
// acquisition lock of a Kafka share group, the AckWait of NATS). A box
// without the feature keeps the old meaning: written to the socket = acked.

// ackTimeout is how long a pushed row may stay unacked on a live socket
// before the relay pushes it again. The box dedups a second copy by file name.
const ackTimeout = 60 * time.Second

// acks is the store's commit support for this session, or nil when the box
// does not commit (or the store cannot keep it).
func (s *Server) acks(x *session) store.Acks {
	a, ok := s.o.Store.(store.Acks)
	if !ok || x.role != wire.RoleBox || !x.has(wire.FeatureCommit) {
		return nil
	}
	return a
}

// onCommit records one commit frame. Fire and forget: no reply, and a bad
// or repeated commit changes nothing.
func (s *Server) onCommit(ctx context.Context, x *session, f wire.Frame) {
	a := s.acks(x)
	if a == nil {
		return
	}
	if _, err := uuid.Parse(f.MsgID); err != nil {
		return
	}
	if err := a.AckDelivery(ctx, x.tenant, f.MsgID, x.box, s.o.Now()); err != nil {
		s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("commit")
	}
}

// pushUnacked pushes again the rows of a committing box that were sent
// before sentBefore and never acked, and returns how many it sent.
func (s *Server) pushUnacked(ctx context.Context, x *session, sentBefore time.Time) int {
	a := s.acks(x)
	if a == nil {
		return 0
	}
	now := s.o.Now()
	q, err := a.UnackedFor(ctx, x.tenant, x.box, now, sentBefore)
	if err != nil {
		s.o.Log.Error().Err(err).Str("tenant", x.tenant).Str("box", x.box).Msg("unacked rows")
		return 0
	}
	n := 0
	for _, d := range q {
		if !x.accepts(wire.InnerVersion(d.Env)) {
			continue
		}
		agents, ok := s.recvAgents(ctx, x, d.Env)
		if !ok {
			continue
		}
		if got, err := a.ReclaimUnacked(ctx, x.tenant, d.MsgID, x.box, now, sentBefore); err != nil || !got {
			continue
		}
		if x.write(ctx, wire.Frame{Type: wire.TRecv, Env: d.Env, Agents: agents}) == nil {
			n++
		}
	}
	return n
}

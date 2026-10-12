package hub

import (
	"context"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The visitor channel retention (specs/121 4.4; T106): a visitor channel is
// removed 30 days after its last message (its mint, when it holds none),
// unless the owner marked it a lead. Removal is the erasure's: the channel,
// its messages, the visitor row (so the token) and the visitor's HUM. It
// runs on every retention tick of RunSweeper, flag on or off: a workspace
// that turns the embed off still owes its visitors the removal.

const (
	// EmbedRetention is how long a visitor channel outlives its last message.
	EmbedRetention = 30 * 24 * time.Hour // Retention period for embed data
	// embedRetentionBatch caps one tick; the next tick takes the rest.
	embedRetentionBatch = 200
)

// SweepEmbedRetention removes the visitor channels due at now and returns
// how many it removed. Each is re-checked under its own channel scope, so a
// post or a lead mark since the read keeps it. A store without visitor
// channels sweeps nothing.
func (s *Server) SweepEmbedRetention(ctx context.Context) (int, error) {
	es, ok := s.o.Store.(store.EmbedStaff)
	if !ok {
		return 0, nil
	}
	before := s.o.Now().UTC().Add(-EmbedRetention)
	due, err := es.EmbedRetentionDue(ctx, before, embedRetentionBatch)
	if err != nil {
		return 0, err
	}
	n := 0
	for _, v := range due {
		gone, err := es.RetireEmbedVisitor(ctx, v, before)
		if err != nil {
			return n, err
		}
		if gone {
			n++
		}
	}
	return n, nil
}

// sweepEmbedRetention is the RunSweeper tick: logs, never fails the loop.
func (s *Server) sweepEmbedRetention(ctx context.Context) {
	n, err := s.SweepEmbedRetention(ctx)
	if err != nil {
		s.o.Log.Error().Err(err).Int("removed", n).Msg("embed visitor retention sweep")
		return
	}
	if n > 0 {
		s.o.Log.Info().Int("removed", n).Msg("embed visitor retention sweep")
	}
}

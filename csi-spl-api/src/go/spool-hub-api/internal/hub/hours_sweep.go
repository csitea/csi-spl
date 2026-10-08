package hub

import (
	"context"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// sweepHours is the hours freeze sweep (spec 107 4.2, T007) on the hub's
// retention tick: frozen period rows at end + grace, the period's raw minutes
// pruned, and the 45-day minute retention. A store without it is a no-op.
func (s *Server) sweepHours(ctx context.Context) {
	hs, ok := s.o.Store.(store.HoursSweeper)
	if !ok {
		return
	}
	r, err := hs.SweepHours(ctx, s.o.Now())
	if err != nil {
		s.o.Log.Error().Err(err).Int("frozen", r.Frozen).Msg("hours freeze sweep")
		return
	}
	if r.Frozen+r.Pruned+r.Aged > 0 {
		s.o.Log.Info().Int("frozen", r.Frozen).Int("pruned", r.Pruned).Int("aged", r.Aged).Msg("hours freeze sweep")
	}
}

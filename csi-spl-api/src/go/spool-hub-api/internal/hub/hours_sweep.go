package hub

import (
	"context"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// sweepHours is the hours freeze sweep (spec 107 4.2, T007) on the hub's
// retention tick: frozen period rows at end + grace from the approved entries
// only, the period's raw minutes pruned, and the 45-day minute retention. It
// approves nothing (owner Q32 = B, spec 23.9, T089): an open suggestion counts
// zero at the freeze.
func (s *Server) sweepHours(ctx context.Context) {
	r, err := s.SweepHours(ctx)
	if err != nil {
		s.o.Log.Error().Err(err).Int("frozen", r.Frozen).Msg("hours freeze sweep")
		return
	}
	if r.Frozen+r.Pruned+r.Aged > 0 {
		s.o.Log.Info().Int("frozen", r.Frozen).Int("pruned", r.Pruned).Int("aged", r.Aged).Msg("hours freeze sweep")
	}
}

// SweepHours runs the freeze sweep for tenants, or for every workspace (and
// the 45-day retention) when none is named. A store without it is a no-op.
// It passes no HoursOpenSuggestions: nil is the store's count-zero path, so
// nothing is auto-approved (owner Q32 = B, spec 23.9).
func (s *Server) SweepHours(ctx context.Context, tenants ...string) (store.HoursSweepResult, error) {
	hs, ok := s.o.Store.(store.HoursSweeper)
	if !ok {
		return store.HoursSweepResult{}, nil
	}
	return hs.SweepHours(ctx, s.o.Now(), nil, tenants...)
}

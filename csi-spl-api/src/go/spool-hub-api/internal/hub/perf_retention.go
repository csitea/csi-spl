package hub

import (
	"context"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// sweepPerfSamples is the retention of the WUI perf samples (spec 066 section
// 4, store.PerfSampleRetention), on the hub's retention sweep.
func (s *Server) sweepPerfSamples(ctx context.Context) {
	ps, ok := s.o.Store.(store.PerfSamples)
	if !ok {
		return
	}
	n, err := ps.PrunePerfSamples(ctx, s.o.Now().Add(-store.PerfSampleRetention))
	if err != nil {
		s.o.Log.Error().Err(err).Msg("wui_perf_samples retention sweep")
		return
	}
	if n > 0 {
		s.o.Log.Info().Int("pruned", n).Msg("wui_perf_samples retention sweep")
	}
}

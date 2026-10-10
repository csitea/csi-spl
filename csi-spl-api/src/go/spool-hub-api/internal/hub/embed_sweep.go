package hub

import (
	"context"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// The embed token sweep (specs/121 4.1, T105; the SweepDemo pattern): on
// each retention tick (RunSweeper) the store retires every visitor token
// expired by now and clears its ip_hash; the channel stays readable to the
// owner until retention (4.4, T106). The same pass drops the embed counters
// no window still reads and the automatic bans that have lapsed.

// embedCountsKeep is how long an embed counter row is kept: past the
// longest window that reads it (a UTC day, the hits window) with a margin.
const embedCountsKeep = 48 * time.Hour

// SweepEmbed is one embed sweep; a store without the embed has nothing to
// sweep.
func (s *Server) SweepEmbed(ctx context.Context) {
	ab, ok := s.o.Store.(store.EmbedAbuse)
	if !ok {
		return
	}
	now := s.o.Now().UTC()
	lim := s.embedLimits()
	keep := max(embedCountsKeep, lim.HitsWindow+time.Hour)
	out, err := ab.SweepEmbed(ctx, now, now.Add(-keep), now.Add(-lim.BanFor))
	if err != nil {
		s.o.Log.Error().Err(err).Msg("embed sweep")
		return
	}
	if out.Tokens+out.Counts+out.Bans > 0 {
		s.o.Log.Info().Int("tokens", out.Tokens).Int("counts", out.Counts).Int("bans", out.Bans).Msg("embed sweep")
	}
}

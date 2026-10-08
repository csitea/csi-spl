package hub

import (
	"context"
	"sort"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hours"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// sweepHours is the hours freeze sweep (spec 107 4.2, T007) on the hub's
// retention tick: frozen period rows at end + grace, open suggestions
// auto-approved first (owner Q2 = B), the period's raw minutes pruned, and the
// 45-day minute retention.
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
func (s *Server) SweepHours(ctx context.Context, tenants ...string) (store.HoursSweepResult, error) {
	hs, ok := s.o.Store.(store.HoursSweeper)
	if !ok {
		return store.HoursSweepResult{}, nil
	}
	return hs.SweepHours(ctx, s.o.Now(), s.hoursOpenSuggestions, tenants...)
}

// hoursOpenSuggestions is store.HoursOpenSuggestions: the member's suggestions
// of the days start..end that have no entry, as approved entries (owner Q2 =
// B), made the way GET /v1/me/hours makes them (suggestHours). A day keeps
// within the cap: its approved entries come first.
func (s *Server) hoursOpenSuggestions(ctx context.Context, tenant, member, start, end string) ([]store.HoursEntry, error) {
	st, ok := s.o.Store.(store.Hours)
	if !ok {
		return nil, nil
	}
	t, err := s.o.Store.GetTenant(ctx, tenant)
	if err != nil {
		return nil, err
	}
	c := hoursMe{tenant: t, hum: member, st: st, set: store.HoursSettingsOf(t.Settings)}
	p := &hoursPeriod{frozen: map[string]bool{}, suggest: map[string]map[string]hours.Row{}}
	if p.start, err = store.ParseHoursDay(start); err != nil {
		return nil, err
	}
	if p.end, err = store.ParseHoursDay(end); err != nil {
		return nil, err
	}
	if p.loc, err = s.hoursZone(ctx, c, s.o.Now()); err != nil {
		return nil, err
	}
	if err := s.suggestHours(ctx, c, p); err != nil {
		return nil, err
	}
	have, err := st.HoursEntries(ctx, tenant, member, start, end)
	if err != nil {
		return nil, err
	}
	decided, used := map[[2]string]bool{}, map[string]int{}
	for _, e := range have {
		decided[[2]string{e.Day, e.Target}] = true
		if e.State == store.HoursApproved {
			used[e.Day] += e.Minutes
		}
	}
	var out []store.HoursEntry
	for _, d := range p.days() {
		rows := p.suggest[d]
		targets := make([]string, 0, len(rows))
		for tg := range rows {
			targets = append(targets, tg)
		}
		sort.Strings(targets)
		for _, tg := range targets {
			n := min(rows[tg].Minutes, store.HoursDayCap-used[d])
			if decided[[2]string{d, tg}] || n <= 0 {
				continue
			}
			used[d] += n
			out = append(out, store.HoursEntry{Day: d, Target: tg, Minutes: n,
				SuggestedMinutes: rows[tg].Minutes, State: store.HoursApproved})
		}
	}
	return out, nil
}

package store

import (
	"context"
	"maps"
	"slices"
	"time"
)

// Memory's marketing metrics (marketing_metrics.go), the Postgres contract
// under s.mu: both are append-only slices per tenant, the sample ids come
// from one counter as the identity does in Postgres.

type memMarketingMetrics struct {
	seq         int64
	samples     map[string][]MarketingMetricSample     // tenant -> rows, oldest first
	definitions map[string][]MarketingMetricDefinition // tenant -> versions, oldest first
}

// marketingMetricsLocked is the state, made on first use; s.mu is held.
func (s *Memory) marketingMetricsLocked() *memMarketingMetrics {
	if s.mktMetrics == nil {
		s.mktMetrics = &memMarketingMetrics{samples: map[string][]MarketingMetricSample{},
			definitions: map[string][]MarketingMetricDefinition{}}
	}
	return s.mktMetrics
}

// AddMarketingMetricSample is MarketingMetrics.AddMarketingMetricSample.
func (s *Memory) AddMarketingMetricSample(_ context.Context, tenant string, m MarketingMetricSample, now time.Time) (MarketingMetricSample, error) {
	if err := checkTenant(tenant); err != nil {
		return MarketingMetricSample{}, err
	}
	m, err := normMarketingSample(m, now)
	if err != nil {
		return MarketingMetricSample{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return MarketingMetricSample{}, ErrNotFound
	}
	st := s.marketingMetricsLocked()
	st.seq++
	m.ID, m.Tenant = st.seq, tenant
	st.samples[tenant] = append(st.samples[tenant], m)
	return m, nil
}

// AddMarketingMetricDefinition is MarketingMetrics.AddMarketingMetricDefinition.
func (s *Memory) AddMarketingMetricDefinition(_ context.Context, tenant string, d MarketingMetricDefinition, now time.Time) (MarketingMetricDefinition, error) {
	if err := checkTenant(tenant); err != nil {
		return MarketingMetricDefinition{}, err
	}
	d, err := normMarketingDefinition(d)
	if err != nil {
		return MarketingMetricDefinition{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[tenant]; !ok {
		return MarketingMetricDefinition{}, ErrNotFound
	}
	st := s.marketingMetricsLocked()
	d.Version = 1
	for _, have := range st.definitions[tenant] {
		if have.Metric == d.Metric && have.Version >= d.Version {
			d.Version = have.Version + 1
		}
	}
	d.Tenant, d.CreatedAt, d.Params = tenant, now, maps.Clone(d.Params)
	st.definitions[tenant] = append(st.definitions[tenant], d)
	return d, nil
}

// ReadMarketingMetrics is MarketingMetrics.ReadMarketingMetrics.
func (s *Memory) ReadMarketingMetrics(_ context.Context, tenant string) (MarketingMetricsRead, error) {
	if err := checkTenant(tenant); err != nil {
		return MarketingMetricsRead{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	st := s.marketingMetricsLocked()
	out := MarketingMetricsRead{Samples: []MarketingMetricSample{}, Definitions: []MarketingMetricDefinition{}}
	for _, m := range st.samples[tenant] { // oldest first: a later fetch of a key replaces it
		i := slices.IndexFunc(out.Samples, func(o MarketingMetricSample) bool { return mktSampleKeyLess(o, m) == 0 })
		switch {
		case i < 0:
			out.Samples = append(out.Samples, m)
		case !m.FetchedAt.Before(out.Samples[i].FetchedAt):
			out.Samples[i] = m
		}
	}
	slices.SortFunc(out.Samples, mktSampleKeyLess)
	newest := map[string]MarketingMetricDefinition{}
	for _, d := range st.definitions[tenant] {
		if d.Version > newest[d.Metric].Version {
			newest[d.Metric] = d
		}
	}
	for _, metric := range slices.Sorted(maps.Keys(newest)) {
		d := newest[metric]
		d.Params = maps.Clone(d.Params)
		out.Definitions = append(out.Definitions, d)
	}
	return out, nil
}

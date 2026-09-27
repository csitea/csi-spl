package store

import (
	"context"
	"time"
)

// Memory side of fallback.go.

type memFallbacks struct {
	responders map[string][]string
	delivered  map[[2]string]FallbackDelivery
}

func (f *memFallbacks) init() {
	if f.responders == nil {
		f.responders = map[string][]string{}
		f.delivered = map[[2]string]FallbackDelivery{}
	}
}

func (s *Memory) TenantResponders(_ context.Context, tenant string) ([]string, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fb.init()
	return append([]string(nil), s.fb.responders[tenant]...), nil
}

func (s *Memory) SetTenantResponders(_ context.Context, tenant string, agents []string) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fb.init()
	if _, ok := s.tenants[tenant]; !ok {
		return ErrNotFound
	}
	if len(agents) == 0 {
		delete(s.fb.responders, tenant)
		return nil
	}
	s.fb.responders[tenant] = append([]string(nil), agents...)
	return nil
}

func (s *Memory) RecordFallback(_ context.Context, d FallbackDelivery) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fb.init()
	k := [2]string{d.TenantID, d.MsgID}
	if _, ok := s.fb.delivered[k]; !ok {
		s.fb.delivered[k] = d
	}
	return nil
}

func (s *Memory) ChannelFallbacks(_ context.Context, tenant, channel string, since time.Time) (FallbackSummary, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fb.init()
	var out FallbackSummary
	for k, d := range s.fb.delivered {
		if k[0] != tenant || d.Channel != channel || d.DeliveredAt.Before(since) {
			continue
		}
		out.Count++
		if out.Count == 1 || d.DeliveredAt.After(out.Last.DeliveredAt) ||
			(d.DeliveredAt.Equal(out.Last.DeliveredAt) && d.MsgID > out.Last.MsgID) {
			out.Last = d
		}
	}
	return out, nil
}

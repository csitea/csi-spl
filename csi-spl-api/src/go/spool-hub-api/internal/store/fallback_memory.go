package store

import (
	"context"
	"time"
)

// Memory side of fallback.go.

type memFallbacks struct {
	responders map[string][]string
	delivered  map[[2]string]FallbackDelivery
	off        map[[2]string]bool // (tenant, channel) opted out, rdb 0068
}

func (f *memFallbacks) init() {
	if f.responders == nil {
		f.responders = map[string][]string{}
		f.delivered = map[[2]string]FallbackDelivery{}
		f.off = map[[2]string]bool{}
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

func (s *Memory) ChannelNoFallback(_ context.Context, tenant, channel string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fb.init()
	return s.fb.off[[2]string{tenant, NormalizeChannel(channel)}], nil
}

func (s *Memory) SetChannelNoFallback(_ context.Context, tenant, channel string, off bool) error {
	channel = NormalizeChannel(channel)
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fb.init()
	s.ch.init()
	if _, ok := s.ch.rows[[2]string{tenant, channel}]; !ok && !IsDefaultChannel(channel) {
		return ErrNotFound
	}
	s.fb.off[[2]string{tenant, channel}] = off
	return nil
}

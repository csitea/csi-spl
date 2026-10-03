package store

import (
	"context"
	"sort"
	"strings"
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
		d.Attempts = 1
		s.fb.delivered[k] = d
	}
	return nil
}

func (s *Memory) ClaimFallback(_ context.Context, d FallbackDelivery) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fb.init()
	k := [2]string{d.TenantID, d.MsgID}
	if _, ok := s.fb.delivered[k]; ok {
		return false, nil
	}
	d.Attempts = 1
	s.fb.delivered[k] = d
	return true, nil
}

func (s *Memory) BumpFallback(_ context.Context, d FallbackDelivery, maxAttempts int) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fb.init()
	k := [2]string{d.TenantID, d.MsgID}
	cur, ok := s.fb.delivered[k]
	if !ok || cur.Attempts >= maxAttempts || !cur.DeliveredAt.Before(d.DeliveredAt) {
		return false, nil
	}
	cur.Attempts++
	cur.DeliveredAt = d.DeliveredAt
	cur.Box, cur.Agent = d.Box, d.Agent
	s.fb.delivered[k] = cur
	return true, nil
}

func (s *Memory) UnheardPosts(_ context.Context, tenant string, since, until time.Time, limit int) ([]Queued, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fb.init()
	var ms []*Message
	for k, m := range s.messages {
		if k[0] != tenant || !humanPostIn(m, since, until) {
			continue
		}
		if _, ok := s.fb.delivered[k]; ok {
			continue
		}
		if !s.wantsFallback(tenant, m) {
			continue
		}
		heard := false
		for dk, d := range s.deliveries {
			if dk[0] == tenant && dk[1] == m.MsgID && dk[2] != "box-wui" && d.state == StateSent {
				heard = true
				break
			}
		}
		if !heard {
			ms = append(ms, m)
		}
	}
	return oldestFirst(ms, limit), nil
}

func (s *Memory) UnansweredPosts(_ context.Context, tenant string, since, until time.Time, limit int) ([]Queued, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fb.init()
	var ms []*Message
	for k, m := range s.messages {
		if k[0] != tenant || !humanPostIn(m, since, until) {
			continue
		}
		if _, ok := s.fb.delivered[k]; ok {
			continue
		}
		if !s.wantsFallback(tenant, m) {
			continue
		}
		if !s.answered(tenant, m) {
			ms = append(ms, m)
		}
	}
	return oldestFirst(ms, limit), nil
}

func (s *Memory) ReescalatablePosts(_ context.Context, tenant string, since, escalatedBefore, until time.Time, maxAttempts, limit int) ([]Queued, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fb.init()
	var ms []*Message
	for k, m := range s.messages {
		if k[0] != tenant || !humanPostIn(m, since, until) {
			continue
		}
		d, ok := s.fb.delivered[k]
		if !ok || !d.DeliveredAt.Before(escalatedBefore) || d.Attempts >= maxAttempts {
			continue
		}
		if !s.wantsFallback(tenant, m) {
			continue
		}
		if !s.answered(tenant, m) {
			ms = append(ms, m)
		}
	}
	sort.Slice(ms, func(i, j int) bool {
		di, dj := s.fb.delivered[[2]string{tenant, ms[i].MsgID}], s.fb.delivered[[2]string{tenant, ms[j].MsgID}]
		if !di.DeliveredAt.Equal(dj.DeliveredAt) {
			return di.DeliveredAt.Before(dj.DeliveredAt)
		}
		return ms[i].MsgID < ms[j].MsgID
	})
	if len(ms) > limit {
		ms = ms[:limit]
	}
	out := make([]Queued, len(ms))
	for i, m := range ms {
		out[i] = Queued{MsgID: m.MsgID, Env: m.Env, LastAgent: s.fb.delivered[[2]string{tenant, m.MsgID}].Agent, TaskID: m.TaskID}
	}
	return out, nil
}

// humanPostIn: m is a signed post a human typed in the WUI, received in
// [since, until) - the only lines the fallback ever answers for.
func humanPostIn(m *Message, since, until time.Time) bool {
	return m.FromBox == "box-wui" && strings.HasPrefix(m.FromID, "HUM-") && m.EnvSig != "" &&
		!m.ReceivedAt.Before(since) && m.ReceivedAt.Before(until)
}

// wantsFallback: m is not a DM to a person and its channel has not opted out.
// The caller holds s.mu.
func (s *Memory) wantsFallback(tenant string, m *Message) bool {
	if m.Channel == "" && (strings.HasPrefix(m.ToID, "HUM-") || strings.HasPrefix(m.ToID, "GST-") || m.ToID == "ALL-0") {
		return false // a DM to a person
	}
	return m.Channel == "" || !s.fb.off[[2]string{tenant, m.Channel}]
}

// answered: an agent (not the WUI, not a human or guest) wrote in m's topic
// after it. The caller holds s.mu.
func (s *Memory) answered(tenant string, m *Message) bool {
	for _, r := range s.messages {
		if r.TenantID == tenant && r.TaskID == m.TaskID && r.ReceivedAt.After(m.ReceivedAt) &&
			r.FromBox != "box-wui" && !strings.HasPrefix(r.FromID, "HUM-") && !strings.HasPrefix(r.FromID, "GST-") {
			return true
		}
	}
	return false
}

// oldestFirst orders posts by received_at, then msg_id, and keeps limit.
func oldestFirst(ms []*Message, limit int) []Queued {
	sort.Slice(ms, func(i, j int) bool {
		if !ms[i].ReceivedAt.Equal(ms[j].ReceivedAt) {
			return ms[i].ReceivedAt.Before(ms[j].ReceivedAt)
		}
		return ms[i].MsgID < ms[j].MsgID
	})
	if len(ms) > limit {
		ms = ms[:limit]
	}
	out := make([]Queued, len(ms))
	for i, m := range ms {
		out[i] = Queued{MsgID: m.MsgID, Env: m.Env, TaskID: m.TaskID}
	}
	return out
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

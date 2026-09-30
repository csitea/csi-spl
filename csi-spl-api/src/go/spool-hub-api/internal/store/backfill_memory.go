package store

import (
	"context"
	"sort"
	"time"
)

// Memory side of backfill.go. A seat's stamp lives in memChannels.backfilled;
// an invited seat without one is pending, as a NULL backfilled_at is.

func (s *Memory) PendingBackfills(_ context.Context, tenant, box string) ([]BackfillSeat, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	var out []BackfillSeat
	for k := range s.ch.invited {
		if k[0] != tenant || k[2] != box || s.ch.archivedCh(tenant, k[1]) {
			continue
		}
		if _, done := s.ch.backfilled[k]; done {
			continue
		}
		out = append(out, BackfillSeat{Channel: k[1], Box: k[2], Agent: k[3]})
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Channel != out[j].Channel {
			return out[i].Channel < out[j].Channel
		}
		return out[i].Agent < out[j].Agent
	})
	return out, nil
}

func (s *Memory) ChannelBackfill(_ context.Context, tenant, channel string, since, now time.Time, limit int) ([]BackfillMsg, error) {
	if limit <= 0 {
		return nil, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	active := map[string]bool{}
	for k, m := range s.messages {
		if k[0] == tenant && m.Channel == channel && !m.ReceivedAt.Before(since) {
			active[m.TaskID] = true
		}
	}
	var rows []*Message
	for k, m := range s.messages {
		if k[0] != tenant || m.Channel != channel || m.EnvSig == "" || !m.ExpiresAt.After(now) ||
			!m.ArchivedAt.IsZero() || !active[m.TaskID] {
			continue
		}
		rows = append(rows, m)
	}
	sort.Slice(rows, func(i, j int) bool {
		if !rows[i].ReceivedAt.Equal(rows[j].ReceivedAt) {
			return rows[i].ReceivedAt.Before(rows[j].ReceivedAt)
		}
		return rows[i].MsgID < rows[j].MsgID
	})
	if len(rows) > limit {
		rows = rows[len(rows)-limit:]
	}
	out := make([]BackfillMsg, 0, len(rows))
	for _, m := range rows {
		out = append(out, BackfillMsg{MsgID: m.MsgID, TaskID: m.TaskID, FromID: m.FromID,
			Env: append([]byte(nil), m.Env...), ReceivedAt: m.ReceivedAt})
	}
	return out, nil
}

func (s *Memory) MarkBackfilled(_ context.Context, tenant, channel, box, agent string, now time.Time) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.ch.init()
	k := [4]string{tenant, channel, box, agent}
	if _, ok := s.ch.invited[k]; !ok {
		return nil
	}
	if _, done := s.ch.backfilled[k]; !done {
		s.ch.backfilled[k] = now
	}
	return nil
}

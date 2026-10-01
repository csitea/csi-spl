package store

import (
	"context"
	"sort"
	"strings"
	"time"
)

// Memory side of replay.go.

func (s *Memory) UnsignedWUIPosts(_ context.Context, tenant string, since, now time.Time, limit int) ([]UnsignedPost, error) {
	if limit <= 0 {
		return nil, nil
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var rows []*Message
	for k, m := range s.messages {
		if k[0] != tenant || m.FromBox != "box-wui" || m.EnvSig != "" || m.Channel == "" ||
			!strings.HasPrefix(m.FromID, "HUM-") || m.ReceivedAt.Before(since) ||
			!m.ExpiresAt.After(now) || !m.ArchivedAt.IsZero() {
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
		rows = rows[:limit]
	}
	out := make([]UnsignedPost, 0, len(rows))
	for _, m := range rows {
		out = append(out, UnsignedPost{MsgID: m.MsgID, Channel: m.Channel, FromID: m.FromID,
			Env: append([]byte(nil), m.Env...), ReceivedAt: m.ReceivedAt})
	}
	return out, nil
}

func (s *Memory) ResignMessage(_ context.Context, tenant, msgID string, env []byte, sig string) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	m, ok := s.messages[[2]string{tenant, msgID}]
	if !ok || m.FromBox != "box-wui" || m.EnvSig != "" {
		return false, nil
	}
	m.Env = append([]byte(nil), env...)
	m.EnvSig = sig
	return true, nil
}

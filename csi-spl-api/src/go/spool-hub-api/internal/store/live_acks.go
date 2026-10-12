package store

import (
	"context"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 053 §4.2 S1, rdb 0186: the box's live ack, one row per (message,
// agent). A box whose hello carries the live_ack feature reports, for each
// agent a recv frame addressed, what its poke did: shown in a live pane (the
// ack), or no live window / refused / the agent exited (a nack). The spec 059
// commit (acks.go) says the inbox copy is written; this says whether a live
// agent was told.

// LiveAckShown is the one outcome that is an ack; every other is a nack.
const LiveAckShown = "shown"

// LiveAck is one recorded (message, agent) poke outcome.
type LiveAck struct {
	TenantID string
	MsgID    string
	Agent    string
	Box      string
	Outcome  string
	AckedAt  time.Time
}

// LiveAcks is implemented by stores that keep the live acks.
type LiveAcks interface {
	// RecordLiveAck stores a, or replaces the outcome of an earlier ack of the
	// same (message, agent): the latest poke is the one that counts. It writes
	// only when the hub sent the message to a.Box (a sent deliveries row), so a
	// box cannot ack a message it never got; ok = it wrote.
	RecordLiveAck(ctx context.Context, a LiveAck) (ok bool, err error)
	// LiveAcksOf lists a message's acks, by agent.
	LiveAcksOf(ctx context.Context, tenantID, msgID string) ([]LiveAck, error)
	// NackedPosts lists signed browser posts by a person that a nack recorded
	// in [since, until) names, that NO agent acked shown, that no fallback took
	// and no agent replied to in their topic, oldest first, at most limit
	// (spec 053 §4.3 S3). Only posts that can fall back, as UnheardPosts.
	NackedPosts(ctx context.Context, tenantID string, since, until time.Time, limit int) ([]Queued, error)
}

// RecordLiveAck implements LiveAcks: an upsert gated on a sent deliveries row.
func (s *Postgres) RecordLiveAck(ctx context.Context, a LiveAck) (bool, error) {
	tag, err := s.execTenant(ctx, a.TenantID, `INSERT INTO delivery_live_acks
		(tenant_id, msg_id, agent_id, box_id, outcome, acked_at)
		SELECT $1, $2, $3, $4, $5, $6 WHERE EXISTS (SELECT 1 FROM deliveries d
		    WHERE d.tenant_id = $1 AND d.msg_id = $2 AND d.to_box = $4 AND d.state = 'sent')
		ON CONFLICT (tenant_id, msg_id, agent_id)
		DO UPDATE SET box_id = EXCLUDED.box_id, outcome = EXCLUDED.outcome, acked_at = EXCLUDED.acked_at`,
		a.TenantID, a.MsgID, a.Agent, a.Box, a.Outcome, a.AckedAt)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

// LiveAcksOf implements LiveAcks.
func (s *Postgres) LiveAcksOf(ctx context.Context, tenant, msgID string) ([]LiveAck, error) {
	var out []LiveAck
	err := s.queryTenant(ctx, tenant, `SELECT agent_id, box_id, outcome, acked_at FROM delivery_live_acks
		WHERE tenant_id = $1 AND msg_id = $2 ORDER BY agent_id`, []any{tenant, msgID}, func(rows pgx.Rows) error {
		a := LiveAck{TenantID: tenant, MsgID: msgID}
		if err := rows.Scan(&a.Agent, &a.Box, &a.Outcome, &a.AckedAt); err != nil {
			return err
		}
		a.AckedAt = a.AckedAt.UTC()
		out = append(out, a)
		return nil
	})
	return out, err
}

// NackedPosts starts from the nacks of the window (the partial index of rdb
// 0186, empty while every poke lands), so a tick with no nack reads nothing
// of messages; the probes are primary-key lookups.
func (s *Postgres) NackedPosts(ctx context.Context, tenant string, since, until time.Time, limit int) ([]Queued, error) {
	var out []Queued
	err := s.queryTenant(ctx, tenant, `SELECT m.msg_id::text, m.env, m.task_id::text FROM messages m
		WHERE m.tenant_id = $1
		  AND m.msg_id IN (SELECT n.msg_id FROM delivery_live_acks n
		                   WHERE n.tenant_id = $1 AND n.outcome <> 'shown'
		                     AND n.acked_at >= $2 AND n.acked_at < $3)
		  AND m.from_box = 'box-wui' AND m.from_id LIKE 'HUM-%' AND m.env_sig <> ''
		  AND (m.channel IS NOT NULL OR (m.to_id NOT LIKE 'HUM-%' AND m.to_id NOT LIKE 'GST-%' AND m.to_id <> 'ALL-0'))
		  AND NOT EXISTS (SELECT 1 FROM channels c
		                  WHERE c.tenant_id = m.tenant_id AND c.channel_id = m.channel AND c.no_fallback)
		  AND NOT EXISTS (SELECT 1 FROM fallback_deliveries f
		                  WHERE f.tenant_id = m.tenant_id AND f.msg_id = m.msg_id)
		  AND NOT EXISTS (SELECT 1 FROM delivery_live_acks y
		                  WHERE y.tenant_id = m.tenant_id AND y.msg_id = m.msg_id AND y.outcome = 'shown')
		  AND NOT EXISTS (SELECT 1 FROM messages r
		                  WHERE r.tenant_id = m.tenant_id AND r.task_id = m.task_id
		                    AND r.received_at > m.received_at
		                    AND r.from_box <> 'box-wui'
		                    AND r.from_id NOT LIKE 'HUM-%' AND r.from_id NOT LIKE 'GST-%')
		ORDER BY m.received_at, m.msg_id LIMIT $4`, []any{tenant, since, until, limit},
		func(rows pgx.Rows) error {
			var q Queued
			if err := rows.Scan(&q.MsgID, &q.Env, &q.TaskID); err != nil {
				return err
			}
			out = append(out, q)
			return nil
		})
	return out, err
}

// RecordLiveAck implements LiveAcks for the in-memory store.
func (s *Memory) RecordLiveAck(_ context.Context, a LiveAck) (bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	d, ok := s.deliveries[[3]string{a.TenantID, a.MsgID, a.Box}]
	if !ok || d.state != StateSent {
		return false, nil
	}
	if s.liveAcks == nil {
		s.liveAcks = map[[3]string]LiveAck{}
	}
	a.AckedAt = a.AckedAt.UTC()
	s.liveAcks[[3]string{a.TenantID, a.MsgID, a.Agent}] = a
	return true, nil
}

// LiveAcksOf implements LiveAcks for the in-memory store.
func (s *Memory) LiveAcksOf(_ context.Context, tenant, msgID string) ([]LiveAck, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []LiveAck
	for k, a := range s.liveAcks {
		if k[0] == tenant && k[1] == msgID {
			out = append(out, a)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Agent < out[j].Agent })
	return out, nil
}

// NackedPosts implements LiveAcks for the in-memory store.
func (s *Memory) NackedPosts(_ context.Context, tenant string, since, until time.Time, limit int) ([]Queued, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.fb.init()
	nacked, shown := map[string]bool{}, map[string]bool{}
	for k, a := range s.liveAcks {
		if k[0] != tenant {
			continue
		}
		if a.Outcome == LiveAckShown {
			shown[k[1]] = true
		} else if !a.AckedAt.Before(since) && a.AckedAt.Before(until) {
			nacked[k[1]] = true
		}
	}
	var ms []*Message
	for id := range nacked {
		k := [2]string{tenant, id}
		m, ok := s.messages[k]
		if !ok || shown[id] || !humanPostIn(m, time.Time{}, until) { // received before its nack
			continue
		}
		if _, taken := s.fb.delivered[k]; taken || !s.wantsFallback(tenant, m) || s.answered(tenant, m) {
			continue
		}
		ms = append(ms, m)
	}
	return oldestFirst(ms, limit), nil
}

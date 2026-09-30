package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of fallback.go (rdb 0067).

func (s *Postgres) TenantResponders(ctx context.Context, tenant string) ([]string, error) {
	var out []string
	err := s.queryRowTenant(ctx, tenant, `SELECT responders FROM tenants WHERE tenant_id = $1`,
		[]any{tenant}, &out)
	if errors.Is(err, pgx.ErrNoRows) {
		return nil, nil
	}
	if len(out) == 0 {
		out = nil
	}
	return out, err
}

func (s *Postgres) SetTenantResponders(ctx context.Context, tenant string, agents []string) error {
	if agents == nil {
		agents = []string{}
	}
	tag, err := s.execTenant(ctx, tenant, `UPDATE tenants SET responders = $2 WHERE tenant_id = $1`, tenant, agents)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) RecordFallback(ctx context.Context, d FallbackDelivery) error {
	_, err := s.execTenant(ctx, d.TenantID, `INSERT INTO fallback_deliveries
		(tenant_id, msg_id, channel_id, box_id, agent_id, delivered_at)
		VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (tenant_id, msg_id) DO NOTHING`,
		d.TenantID, d.MsgID, d.Channel, d.Box, d.Agent, d.DeliveredAt)
	return err
}

func (s *Postgres) ClaimFallback(ctx context.Context, d FallbackDelivery) (bool, error) {
	tag, err := s.execTenant(ctx, d.TenantID, `INSERT INTO fallback_deliveries
		(tenant_id, msg_id, channel_id, box_id, agent_id, delivered_at)
		VALUES ($1, $2, $3, $4, $5, $6) ON CONFLICT (tenant_id, msg_id) DO NOTHING`,
		d.TenantID, d.MsgID, d.Channel, d.Box, d.Agent, d.DeliveredAt)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

// UnheardPosts walks messages_received (tenant_id, received_at) over a
// window of minutes; the NOT EXISTS probes are primary-key lookups. A DM to
// a person and a channel that opted out (rdb 0068) never fall back, so they
// are left out here rather than re-read every tick.
func (s *Postgres) UnheardPosts(ctx context.Context, tenant string, since, until time.Time, limit int) ([]Queued, error) {
	var out []Queued
	err := s.queryTenant(ctx, tenant, `SELECT m.msg_id::text, m.env FROM messages m
		WHERE m.tenant_id = $1 AND m.received_at >= $2 AND m.received_at < $3
		  AND m.from_box = 'box-wui' AND m.from_id LIKE 'HUM-%' AND m.env_sig <> ''
		  AND (m.channel IS NOT NULL OR (m.to_id NOT LIKE 'HUM-%' AND m.to_id NOT LIKE 'GST-%' AND m.to_id <> 'ALL-0'))
		  AND NOT EXISTS (SELECT 1 FROM channels c
		                  WHERE c.tenant_id = m.tenant_id AND c.channel_id = m.channel AND c.no_fallback)
		  AND NOT EXISTS (SELECT 1 FROM fallback_deliveries f
		                  WHERE f.tenant_id = m.tenant_id AND f.msg_id = m.msg_id)
		  AND NOT EXISTS (SELECT 1 FROM deliveries d
		                  WHERE d.tenant_id = m.tenant_id AND d.msg_id = m.msg_id
		                    AND d.to_box <> 'box-wui' AND d.state = 'sent')
		ORDER BY m.received_at, m.msg_id LIMIT $4`, []any{tenant, since, until, limit},
		func(rows pgx.Rows) error {
			var q Queued
			if err := rows.Scan(&q.MsgID, &q.Env); err != nil {
				return err
			}
			out = append(out, q)
			return nil
		})
	return out, err
}

// UnansweredPosts is UnheardPosts's sibling for SPL-1225: it drops the
// "an agent box was sent the frame" exclusion (which box-desk always
// satisfies for a channel post) and replaces it with "no agent replied in
// the topic". A reply is any later message in the same task from a non-human
// sender (an agent posts through its desk, so from_box <> 'box-wui' and
// from_id is not a HUM-/GST- id).
func (s *Postgres) UnansweredPosts(ctx context.Context, tenant string, since, until time.Time, limit int) ([]Queued, error) {
	var out []Queued
	err := s.queryTenant(ctx, tenant, `SELECT m.msg_id::text, m.env FROM messages m
		WHERE m.tenant_id = $1 AND m.received_at >= $2 AND m.received_at < $3
		  AND m.from_box = 'box-wui' AND m.from_id LIKE 'HUM-%' AND m.env_sig <> ''
		  AND (m.channel IS NOT NULL OR (m.to_id NOT LIKE 'HUM-%' AND m.to_id NOT LIKE 'GST-%' AND m.to_id <> 'ALL-0'))
		  AND NOT EXISTS (SELECT 1 FROM channels c
		                  WHERE c.tenant_id = m.tenant_id AND c.channel_id = m.channel AND c.no_fallback)
		  AND NOT EXISTS (SELECT 1 FROM fallback_deliveries f
		                  WHERE f.tenant_id = m.tenant_id AND f.msg_id = m.msg_id)
		  AND NOT EXISTS (SELECT 1 FROM messages r
		                  WHERE r.tenant_id = m.tenant_id AND r.task_id = m.task_id
		                    AND r.received_at > m.received_at
		                    AND r.from_box <> 'box-wui'
		                    AND r.from_id NOT LIKE 'HUM-%' AND r.from_id NOT LIKE 'GST-%')
		ORDER BY m.received_at, m.msg_id LIMIT $4`, []any{tenant, since, until, limit},
		func(rows pgx.Rows) error {
			var q Queued
			if err := rows.Scan(&q.MsgID, &q.Env); err != nil {
				return err
			}
			out = append(out, q)
			return nil
		})
	return out, err
}

func (s *Postgres) ChannelFallbacks(ctx context.Context, tenant, channel string, since time.Time) (FallbackSummary, error) {
	var out FallbackSummary
	err := s.queryTenant(ctx, tenant, `SELECT msg_id::text, box_id, agent_id, delivered_at,
			count(*) OVER () FROM fallback_deliveries
		WHERE tenant_id = $1 AND channel_id = $2 AND delivered_at >= $3
		ORDER BY delivered_at DESC, msg_id DESC LIMIT 1`, []any{tenant, channel, since},
		func(rows pgx.Rows) error {
			d := FallbackDelivery{TenantID: tenant, Channel: channel}
			if err := rows.Scan(&d.MsgID, &d.Box, &d.Agent, &d.DeliveredAt, &out.Count); err != nil {
				return err
			}
			out.Last = d
			return nil
		})
	return out, err
}

func (s *Postgres) ChannelNoFallback(ctx context.Context, tenant, channel string) (bool, error) {
	var off bool
	err := s.queryRowTenant(ctx, tenant, `SELECT no_fallback FROM channels WHERE tenant_id = $1 AND channel_id = $2`,
		[]any{tenant, NormalizeChannel(channel)}, &off)
	if errors.Is(err, pgx.ErrNoRows) {
		return false, nil
	}
	return off, err
}

func (s *Postgres) SetChannelNoFallback(ctx context.Context, tenant, channel string, off bool) error {
	tag, err := s.execTenant(ctx, tenant, `UPDATE channels SET no_fallback = $3 WHERE tenant_id = $1 AND channel_id = $2`,
		tenant, NormalizeChannel(channel), off)
	if err != nil {
		return err
	}
	if tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return nil
}

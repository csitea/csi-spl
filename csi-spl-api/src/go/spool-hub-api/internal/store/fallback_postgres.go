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

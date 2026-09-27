package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of backfill.go (rdb 0066).

func (s *Postgres) PendingBackfills(ctx context.Context, tenant, box string) ([]BackfillSeat, error) {
	var out []BackfillSeat
	err := s.queryTenant(ctx, tenant, `SELECT channel_id, box_id, agent_id FROM channel_subscriptions
		WHERE tenant_id = $1 AND box_id = $2 AND origin = 'invite' AND backfilled_at IS NULL
		AND `+notDeleted("channel_subscriptions.channel_id")+`
		ORDER BY channel_id, agent_id`, []any{tenant, box}, func(rows pgx.Rows) error {
		var b BackfillSeat
		if err := rows.Scan(&b.Channel, &b.Box, &b.Agent); err != nil {
			return err
		}
		out = append(out, b)
		return nil
	})
	return out, err
}

// ChannelBackfill reads the newest `limit` signed rows of the channel's
// active topics and returns them oldest first. The topic set is every task
// with a row in the channel received since `since`; its older rows come too,
// so an agent sees a live thread from its root.
func (s *Postgres) ChannelBackfill(ctx context.Context, tenant, channel string, since, now time.Time, limit int) ([]BackfillMsg, error) {
	if limit <= 0 {
		return nil, nil
	}
	var out []BackfillMsg
	err := s.queryTenant(ctx, tenant, `SELECT msg_id, task_id, from_id, env, received_at FROM (
			SELECT m.msg_id::text, m.task_id::text, m.from_id, m.env, m.received_at FROM messages m
			WHERE m.tenant_id = $1 AND m.channel = $2 AND m.env_sig <> '' AND m.expires_at > $4
			  AND m.archived_at IS NULL
			  AND m.task_id IN (SELECT a.task_id FROM messages a
			                    WHERE a.tenant_id = $1 AND a.channel = $2 AND a.received_at >= $3)
			ORDER BY m.received_at DESC, m.msg_id DESC
			LIMIT $5) x
		ORDER BY received_at, msg_id`, []any{tenant, channel, since, now, limit}, func(rows pgx.Rows) error {
		var b BackfillMsg
		if err := rows.Scan(&b.MsgID, &b.TaskID, &b.FromID, &b.Env, &b.ReceivedAt); err != nil {
			return err
		}
		out = append(out, b)
		return nil
	})
	return out, err
}

func (s *Postgres) MarkBackfilled(ctx context.Context, tenant, channel, box, agent string, now time.Time) error {
	_, err := s.execTenant(ctx, tenant, `UPDATE channel_subscriptions SET backfilled_at = $5
		WHERE tenant_id = $1 AND channel_id = $2 AND box_id = $3 AND agent_id = $4
		  AND backfilled_at IS NULL`, tenant, channel, box, agent, now)
	return err
}

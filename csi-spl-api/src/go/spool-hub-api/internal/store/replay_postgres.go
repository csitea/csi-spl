package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of replay.go.

func (s *Postgres) UnsignedWUIPosts(ctx context.Context, tenant string, since, now time.Time, limit int) ([]UnsignedPost, error) {
	if limit <= 0 {
		return nil, nil
	}
	var out []UnsignedPost
	err := s.queryTenant(ctx, tenant, `SELECT msg_id::text, channel, from_id, env, received_at FROM messages
		WHERE tenant_id = $1 AND from_box = 'box-wui' AND env_sig = '' AND channel IS NOT NULL
		  AND from_id LIKE 'HUM-%' AND received_at >= $2 AND expires_at > $3 AND archived_at IS NULL
		ORDER BY received_at, msg_id
		LIMIT $4`, []any{tenant, since, now, limit}, func(rows pgx.Rows) error {
		var p UnsignedPost
		if err := rows.Scan(&p.MsgID, &p.Channel, &p.FromID, &p.Env, &p.ReceivedAt); err != nil {
			return err
		}
		out = append(out, p)
		return nil
	})
	return out, err
}

func (s *Postgres) ResignMessage(ctx context.Context, tenant, msgID string, env []byte, sig string) (bool, error) {
	tag, err := s.execTenant(ctx, tenant, `UPDATE messages SET env = $3, env_sig = $4
		WHERE tenant_id = $1 AND msg_id = $2 AND from_box = 'box-wui' AND env_sig = ''`, tenant, msgID, env, sig)
	if err != nil {
		return false, err
	}
	return tag.RowsAffected() == 1, nil
}

package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of the human post guard (rdb 0211). Both reads stay inside
// one tenant's index range: messages_task (tenant_id, task_id, ts) for the
// opener, messages_to_human (tenant_id, to_id, received_at) for the body;
// spool_norm_body() filters only the rows that range holds.

// TopicOpener implements HumanPostGuard on the messages_task index.
func (s *Postgres) TopicOpener(ctx context.Context, tenant, taskID string) (TopicOpener, error) {
	var o TopicOpener
	err := s.queryRowTenant(ctx, tenant, `SELECT from_id, to_id, kind FROM messages
		WHERE tenant_id = $1 AND task_id = $2
		ORDER BY received_at, msg_id LIMIT 1`, []any{tenant, taskID}, &o.FromID, &o.ToID, &o.Kind)
	if errors.Is(err, pgx.ErrNoRows) {
		return TopicOpener{}, nil
	}
	return o, err
}

// HumanGotBody implements HumanPostGuard on the messages_to_human index.
func (s *Postgres) HumanGotBody(ctx context.Context, tenant, human, body string, since time.Time, exceptMsgID string) (string, error) {
	var id string
	err := s.queryRowTenant(ctx, tenant, `SELECT msg_id::text FROM messages
		WHERE tenant_id = $1 AND to_id = $2 AND received_at >= $3
		  AND msg_id::text <> $4 AND from_id NOT LIKE 'HUM-%'
		  AND spool_norm_body(body) = spool_norm_body($5)
		ORDER BY received_at DESC LIMIT 1`, []any{tenant, human, since, exceptMsgID, body}, &id)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", nil
	}
	return id, err
}

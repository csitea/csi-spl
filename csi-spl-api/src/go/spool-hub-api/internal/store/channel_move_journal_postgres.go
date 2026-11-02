// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"time"
)

// TaskMoveState is one statement, one round trip: the send path spends it in
// place of TaskFirstChannel.
func (s *Postgres) TaskMoveState(ctx context.Context, tenant, taskID string) (TaskMoveState, error) {
	var out TaskMoveState
	var dst, ref, move *string
	var expires *time.Time
	err := s.queryRowTenant(ctx, tenant, `SELECT COALESCE(f.channel, ''), f.task_id IS NOT NULL,
			r.dst_tenant_id, r.new_ref, r.move_id::text, r.expires_at
		FROM (SELECT 1) one
		LEFT JOIN LATERAL (SELECT channel, task_id FROM messages WHERE tenant_id = $1 AND task_id = $2::uuid
			ORDER BY received_at, msg_id LIMIT 1) f ON true
		LEFT JOIN channel_move_redirects r ON r.src_tenant_id = $1 AND r.kind = 'task' AND r.old_ref = $3`,
		[]any{tenant, taskID, taskID}, &out.FirstChannel, &out.HasRows, &dst, &ref, &move, &expires)
	if err != nil {
		return TaskMoveState{}, err
	}
	if dst != nil {
		out.Redirect = &ChannelMoveRedirect{Dst: *dst, NewRef: *ref, MoveID: *move, ExpiresAt: expires.UTC()}
	}
	return out, nil
}

// MessageCopied reads messages.copied_from; a row not there is not a copy.
func (s *Postgres) MessageCopied(ctx context.Context, tenant, msgID string) (bool, error) {
	var copied bool
	err := s.queryRowTenant(ctx, tenant, `SELECT EXISTS (SELECT 1 FROM messages WHERE tenant_id = $1 AND msg_id = $2::uuid AND copied_from IS NOT NULL)`,
		[]any{tenant, msgID}, &copied)
	return copied, err
}

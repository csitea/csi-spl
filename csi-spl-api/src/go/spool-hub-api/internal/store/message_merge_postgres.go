package store

import (
	"context"

	"github.com/jackc/pgx/v5"
)

// MergeMessages is the Postgres side of message_merge.go: one transaction,
// both rows locked first (in msg_id order, so two merges of the same pair
// queue rather than deadlock), then the reply check, the edit and the delete.
func (s *Postgres) MergeMessages(ctx context.Context, tenant, keepID, dropID string, e Edit) (int, error) {
	if !canonUUIDRe.MatchString(keepID) || !canonUUIDRe.MatchString(dropID) {
		return 0, ErrNotFound
	}
	rev := 0
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		n := 0
		err := eachRow(ctx, tx, `SELECT msg_id::text FROM messages
			WHERE tenant_id = $1 AND msg_id IN ($2, $3) ORDER BY msg_id FOR UPDATE`,
			[]any{tenant, keepID, dropID}, func(rows pgx.Rows) error {
				n++
				return nil
			})
		if err != nil {
			return err
		}
		if n != 2 {
			return ErrNotFound
		}
		var replies bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM messages
			WHERE tenant_id = $1 AND task_id = $2 AND msg_id <> $2)`, tenant, dropID).Scan(&replies); err != nil {
			return err
		}
		if replies {
			return ErrMergeHasReplies
		}
		if rev, err = applyEditTx(ctx, tx, tenant, keepID, e); err != nil {
			return err
		}
		// message_revisions, message_reactions, deliveries and the rest
		// reference messages ON DELETE CASCADE (DeleteMessage).
		tag, err := tx.Exec(ctx, `DELETE FROM messages WHERE tenant_id = $1 AND msg_id = $2`, tenant, dropID)
		if err != nil {
			return err
		}
		if tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return nil
	})
	if err != nil {
		return 0, err
	}
	return rev, nil
}

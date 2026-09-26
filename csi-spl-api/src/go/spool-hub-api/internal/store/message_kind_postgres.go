package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of SPL-952: set a message's kind and append to the register
// (rdb 0060_message_kind_changes.sql), in the tenant scope.

func (s *Postgres) SetKind(ctx context.Context, tenant, msgID, kind, by string, at time.Time) (KindChange, error) {
	var c KindChange
	if !canonUUIDRe.MatchString(msgID) {
		return c, ErrNotFound
	}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		// FOR UPDATE serialises two concurrent changes of one message, so
		// both cannot read the same MAX(seq) (the ApplyEdit pattern).
		var cur string
		err := tx.QueryRow(ctx, `SELECT kind FROM messages
			WHERE tenant_id = $1 AND msg_id = $2 FOR UPDATE`, tenant, msgID).Scan(&cur)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		if cur == kind {
			return nil
		}
		if err := tx.QueryRow(ctx, `INSERT INTO message_kind_changes (tenant_id, msg_id, seq, kind_from, kind_to, set_by, set_at)
			SELECT $1, $2, COALESCE(MAX(seq), 0) + 1, $3, $4, $5, $6
			FROM message_kind_changes WHERE tenant_id = $1 AND msg_id = $2
			RETURNING seq`, tenant, msgID, cur, kind, by, at).Scan(&c.Seq); err != nil {
			return err
		}
		c.From, c.To, c.SetBy, c.SetAt = cur, kind, by, at
		_, err = tx.Exec(ctx, `UPDATE messages SET kind = $3, kind_set_by = $4, kind_set_at = $5
			WHERE tenant_id = $1 AND msg_id = $2`, tenant, msgID, kind, by, at)
		return err
	})
	if err != nil {
		return KindChange{}, err
	}
	return c, nil
}

func (s *Postgres) KindChanges(ctx context.Context, tenant, msgID string) ([]KindChange, error) {
	if !canonUUIDRe.MatchString(msgID) {
		return nil, nil
	}
	out := []KindChange{}
	err := s.queryTenant(ctx, tenant, `SELECT seq, kind_from, kind_to, set_by, set_at FROM message_kind_changes
		WHERE tenant_id = $1 AND msg_id = $2 ORDER BY seq`, []any{tenant, msgID},
		func(rows pgx.Rows) error {
			var c KindChange
			if err := rows.Scan(&c.Seq, &c.From, &c.To, &c.SetBy, &c.SetAt); err != nil {
				return err
			}
			out = append(out, c)
			return nil
		})
	return out, err
}

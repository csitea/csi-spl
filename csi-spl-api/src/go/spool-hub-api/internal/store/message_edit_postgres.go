package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of specs/032: the edit path and the append-only register
// (rdb 0026_message_revisions.sql). Every statement runs in the tenant scope,
// so a forgotten WHERE tenant_id still cannot reach another tenant's message.

func (s *Postgres) GetEditable(ctx context.Context, tenant, msgID string, now time.Time) (EditableMessage, error) {
	var m EditableMessage
	// A non-UUID id can only be a 404; asking Postgres would be an error, not
	// an answer (ViewTopic takes the same guard).
	if !canonUUIDRe.MatchString(msgID) {
		return m, ErrNotFound
	}
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var channel, parent, editedBy *string
		var editedAt *time.Time
		err := tx.QueryRow(ctx, `SELECT msg_id::text, task_id::text, channel, parent_task_id::text,
				from_box, from_id, to_box, to_id, kind, body, msg, env_sig, env, ts, received_at,
				edited_at, edited_by,
				COALESCE((SELECT MAX(revision) FROM message_revisions r
					WHERE r.tenant_id = m.tenant_id AND r.msg_id = m.msg_id), 0)
			FROM messages m
			WHERE m.tenant_id = $1 AND m.msg_id = $2 AND m.expires_at > $3`,
			tenant, msgID, now).Scan(&m.MsgID, &m.TaskID, &channel, &parent,
			&m.FromBox, &m.FromID, &m.ToBox, &m.ToID, &m.Kind, &m.Body, &m.Msg, &m.EnvSig, &m.Env,
			&m.TS, &m.ReceivedAt, &editedAt, &editedBy, &m.Revision)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		m.Channel, m.ParentTaskID = deref(channel), deref(parent)
		m.EditedBy = deref(editedBy)
		if editedAt != nil {
			m.EditedAt = *editedAt
		}
		m.Deliveries = []ViewDelivery{}
		return eachRow(ctx, tx, `SELECT to_box, state FROM deliveries
			WHERE tenant_id = $1 AND msg_id = $2 ORDER BY to_box`, []any{tenant, msgID},
			func(rows pgx.Rows) error {
				var d ViewDelivery
				if err := rows.Scan(&d.ToBox, &d.State); err != nil {
					return err
				}
				m.Deliveries = append(m.Deliveries, d)
				return nil
			})
	})
	if err != nil {
		return EditableMessage{}, err
	}
	return m, nil
}

func (s *Postgres) ApplyEdit(ctx context.Context, tenant, msgID string, e Edit) (int, error) {
	if !canonUUIDRe.MatchString(msgID) {
		return 0, ErrNotFound
	}
	rev := 0
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		// FOR UPDATE serialises two concurrent edits of one message: without
		// it both would read the same MAX(revision) and one INSERT would lose
		// the primary key race instead of queueing behind the other.
		var body, fromID string
		var receivedAt time.Time
		err := tx.QueryRow(ctx, `SELECT body, from_id, received_at FROM messages
			WHERE tenant_id = $1 AND msg_id = $2 FOR UPDATE`, tenant, msgID).Scan(&body, &fromID, &receivedAt)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		// Revision 1 is the body as first sent. Captured here, in the same
		// transaction that replaces it, so no edit can ever lose it — not on a
		// crash between the two writes, because there is no between.
		if _, err := tx.Exec(ctx, `INSERT INTO message_revisions (tenant_id, msg_id, revision, body, edited_by, edited_at)
			SELECT $1, $2, 1, $3, $4, $5
			WHERE NOT EXISTS (SELECT 1 FROM message_revisions WHERE tenant_id = $1 AND msg_id = $2)`,
			tenant, msgID, body, fromID, receivedAt); err != nil {
			return err
		}
		if err := tx.QueryRow(ctx, `INSERT INTO message_revisions (tenant_id, msg_id, revision, body, edited_by, edited_at)
			SELECT $1, $2, COALESCE(MAX(revision), 0) + 1, $3, $4, $5
			FROM message_revisions WHERE tenant_id = $1 AND msg_id = $2
			RETURNING revision`, tenant, msgID, e.Body, e.EditedBy, e.EditedAt).Scan(&rev); err != nil {
			return err
		}
		// Two existing mechanisms ride on this UPDATE, and both do the right
		// thing without being asked: messages.search_tsv is a STORED GENERATED
		// column over body (rdb 0020), so search follows the edit; and the
		// period counters trigger on UPDATE OF tenant_id, received_at only
		// (rdb 0023), neither of which an edit touches, so an edit does not
		// spend quota — it is not a new message.
		_, err = tx.Exec(ctx, `UPDATE messages SET body = $3, msg = $4, env = $5, edited_at = $6, edited_by = $7
			WHERE tenant_id = $1 AND msg_id = $2`,
			tenant, msgID, e.Body, string(e.Msg), e.Env, e.EditedAt, e.EditedBy)
		return err
	})
	if err != nil {
		return 0, err
	}
	return rev, nil
}

func (s *Postgres) MessageRevisions(ctx context.Context, tenant, msgID string) ([]MessageRevision, error) {
	if !canonUUIDRe.MatchString(msgID) {
		return nil, nil
	}
	out := []MessageRevision{}
	err := s.queryTenant(ctx, tenant, `SELECT revision, body, edited_by, edited_at FROM message_revisions
		WHERE tenant_id = $1 AND msg_id = $2 ORDER BY revision`, []any{tenant, msgID},
		func(rows pgx.Rows) error {
			var r MessageRevision
			if err := rows.Scan(&r.Revision, &r.Body, &r.EditedBy, &r.EditedAt); err != nil {
				return err
			}
			out = append(out, r)
			return nil
		})
	return out, err
}

// DeleteMessage removes the row. message_revisions, message_reactions and
// deliveries reference it ON DELETE CASCADE, so the register, the emoji and
// the queue go with it.
func (s *Postgres) DeleteMessage(ctx context.Context, tenant, msgID string) error {
	if !canonUUIDRe.MatchString(msgID) {
		return ErrNotFound
	}
	n := int64(0)
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM messages WHERE tenant_id = $1 AND msg_id = $2`, tenant, msgID)
		if err != nil {
			return err
		}
		n = tag.RowsAffected()
		return nil
	})
	if err != nil {
		return err
	}
	if n == 0 {
		return ErrNotFound
	}
	return nil
}

// deref is "" for a NULL text column.
func deref(p *string) string {
	if p == nil {
		return ""
	}
	return *p
}

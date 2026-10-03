package store

import (
	"context"
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
	// One batch, one round trip (perf round 4 G6), where inTenant paid BEGIN,
	// scope, SELECT, INSERT, UPDATE, COMMIT. The batch is one implicit
	// transaction. The FOR UPDATE stays its own statement on purpose: it
	// serialises two concurrent changes of one message (the ApplyEdit
	// pattern), and the write after it takes a fresh READ COMMITTED snapshot,
	// so its MAX(seq) sees the change it waited for. Folded into the write's
	// own CTE, the lock would wait, but MAX(seq) would read the snapshot from
	// before the wait and repeat a seq.
	lock := tenantRead{sql: `SELECT 1 FROM messages
		WHERE tenant_id = $1 AND msg_id = $2 FOR UPDATE`, args: []any{tenant, msgID},
		each: func(pgx.Rows) error { return nil }}
	found := false
	write := tenantRead{sql: `WITH cur AS (
			SELECT kind FROM messages WHERE tenant_id = $1 AND msg_id = $2
		), ins AS (
			INSERT INTO message_kind_changes (tenant_id, msg_id, seq, kind_from, kind_to, set_by, set_at)
			SELECT $1, $2, COALESCE((SELECT MAX(seq) FROM message_kind_changes
				WHERE tenant_id = $1 AND msg_id = $2), 0) + 1, cur.kind, $3, $4, $5
			FROM cur WHERE cur.kind <> $3
			RETURNING seq, kind_from
		), upd AS (
			UPDATE messages SET kind = $3, kind_set_by = $4, kind_set_at = $5
			WHERE tenant_id = $1 AND msg_id = $2 AND EXISTS (SELECT 1 FROM ins)
		)
		SELECT COALESCE((SELECT seq FROM ins), 0), COALESCE((SELECT kind_from FROM ins), '')
		FROM cur`, args: []any{tenant, msgID, kind, by, at}, each: func(rows pgx.Rows) error {
		found = true
		return rows.Scan(&c.Seq, &c.From)
	}}
	if err := s.queryTenantBatch(ctx, tenant, lock, write); err != nil {
		return KindChange{}, err
	}
	if !found {
		return KindChange{}, ErrNotFound
	}
	if c.Seq == 0 { // already that kind: nothing recorded
		return KindChange{}, nil
	}
	c.To, c.SetBy, c.SetAt = kind, by, at
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

package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of rdb 0037. Every statement runs in the tenant scope.

func (s *Postgres) AddReaction(ctx context.Context, tenant, msgID, actor, emoji string, now time.Time) error {
	if !canonUUIDRe.MatchString(msgID) {
		return ErrNotFound
	}
	// One statement, one round trip (perf round 4 G6): the insert and the
	// "is the message there" answer a no-op insert needs ride the scope batch,
	// where inTenant paid BEGIN, scope, INSERT, a follow-up SELECT, COMMIT.
	var live bool
	err := s.queryRowTenant(ctx, tenant, `WITH m AS (
			SELECT 1 FROM messages
			WHERE tenant_id = $1 AND msg_id = $2 AND expires_at > $5
		), ins AS (
			INSERT INTO message_reactions (tenant_id, msg_id, actor, emoji, created_at)
			SELECT $1, $2, $3, $4, $5 FROM m
			ON CONFLICT DO NOTHING
		)
		SELECT EXISTS (SELECT 1 FROM m)`, []any{tenant, msgID, actor, emoji, now}, &live)
	if err != nil {
		return err
	}
	if !live {
		return ErrNotFound
	}
	return nil
}

func (s *Postgres) RemoveReaction(ctx context.Context, tenant, msgID, actor, emoji string, now time.Time) error {
	if !canonUUIDRe.MatchString(msgID) {
		return ErrNotFound
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var one int
		err := tx.QueryRow(ctx, `SELECT 1 FROM messages
			WHERE tenant_id = $1 AND msg_id = $2 AND expires_at > $3`, tenant, msgID, now).Scan(&one)
		if errors.Is(err, pgx.ErrNoRows) {
			return ErrNotFound
		}
		if err != nil {
			return err
		}
		_, err = tx.Exec(ctx, `DELETE FROM message_reactions
			WHERE tenant_id = $1 AND msg_id = $2 AND actor = $3 AND emoji = $4`,
			tenant, msgID, actor, emoji)
		return err
	})
}

func (s *Postgres) ReactionsFor(ctx context.Context, tenant string, msgIDs []string) (map[string][]StoredReaction, error) {
	out := map[string][]StoredReaction{}
	ids := make([]string, 0, len(msgIDs))
	for _, id := range msgIDs {
		if canonUUIDRe.MatchString(id) {
			ids = append(ids, id)
		}
	}
	if len(ids) == 0 {
		return out, nil
	}
	if got, ok := memoReactions(ctx, tenant, ids); ok { // SPL-1121: read with the view's deliveries
		return got, nil
	}
	r := reactionsRead(tenant, ids, out)
	err := s.queryTenant(ctx, tenant, r.sql, r.args, r.each)
	return out, err
}

// reactionsRead is ReactionsFor's statement (ids already canonical), shared
// with ViewTopic's deliveries batch.
func reactionsRead(tenant string, ids []string, out map[string][]StoredReaction) tenantRead {
	return tenantRead{sql: `SELECT msg_id::text, emoji, actor FROM message_reactions
		WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[])
		ORDER BY created_at, actor`, args: []any{tenant, ids}, each: func(rows pgx.Rows) error {
		var id, emoji, actor string
		if err := rows.Scan(&id, &emoji, &actor); err != nil {
			return err
		}
		out[id] = append(out[id], StoredReaction{Emoji: emoji, Actor: actor})
		return nil
	}}
}

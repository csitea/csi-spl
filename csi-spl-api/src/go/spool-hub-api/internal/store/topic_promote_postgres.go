package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of the topic promote (topic_promote.go, 8f588edd). Every
// statement runs in the tenant scope. The move columns follow markRow, so the
// promoted card is indistinguishable from a moved row to the view reads; the
// four writes are promote's own:
//
//	1. record home     moved_from_task / moved_from_parent on the promoted row
//	                   and every sub-thread row hung off the source task (first
//	                   move keeps the home)
//	2. re-seat card    the promoted row -> the new task, is_parent 1, and a
//	                   same-channel mark (moved_from_channel = channel, at/by)
//	3. repoint         a sub-thread's parent off the source task onto the new one
//
// The sub-thread rows are NOT re-channelled and carry no moved_at, so they show
// no provenance; only their home columns are set, for the undo.

func (s *Postgres) PromoteMessage(ctx context.Context, tenant, srcMsgID, srcTask, newTask, by string, at time.Time) (MoveResult, error) {
	if !canonUUIDRe.MatchString(srcMsgID) || !canonUUIDRe.MatchString(srcTask) || !canonUUIDRe.MatchString(newTask) {
		return MoveResult{}, ErrNotFound
	}
	var res MoveResult
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		set, err := topicTx(ctx, tx, tenant, srcMsgID, "") // locks the row FOR UPDATE, walks its own thread
		if err != nil {
			return err
		}
		for _, tk := range set.TaskIDs {
			if tk == newTask {
				return ErrMoveCycle
			}
		}
		res.MsgIDs, res.TaskIDs, res.Moved = set.MsgIDs, set.TaskIDs, true
		return tx.QueryRow(ctx, promoteCTE, tenant, srcMsgID, srcTask, newTask, set.MsgIDs, at, by).Scan(&res.ReceivedAt)
	})
	if err != nil {
		return MoveResult{}, err
	}
	return res, nil
}

// promoteCTE is promote's three writes and the received_at read in ONE
// statement (perf round 4 G5): the promoted row ($2) and every sub-thread row
// of $5 hung off the source task ($3) are written once, each SET expression
// reading the row as it was, as the three UPDATEs in a row did. Only those
// rows are touched; cur holds them FOR UPDATE (the promoted row is already
// held by topicTx).
const promoteCTE = `WITH cur AS (
		SELECT msg_id, msg_id = $2::uuid AS is_src FROM messages
		WHERE tenant_id = $1 AND msg_id = ANY($5::uuid[]) AND (msg_id = $2::uuid OR parent_task_id = $3::uuid)
		FOR UPDATE
	), upd AS (
		UPDATE messages m SET
			moved_from_parent  = CASE WHEN m.moved_from_task IS NULL THEN m.parent_task_id ELSE m.moved_from_parent END,
			moved_from_task    = COALESCE(m.moved_from_task, m.task_id),
			task_id            = CASE WHEN c.is_src THEN $4::uuid ELSE m.task_id END,
			parent_task_id     = CASE WHEN c.is_src THEN NULL ELSE $4::uuid END,
			is_parent          = CASE WHEN c.is_src THEN 1 ELSE m.is_parent END,
			moved_from_channel = CASE WHEN c.is_src AND m.moved_at IS NULL THEN m.channel ELSE m.moved_from_channel END,
			moved_at           = CASE WHEN c.is_src THEN $6::timestamptz ELSE m.moved_at END,
			moved_by           = CASE WHEN c.is_src THEN $7::text ELSE m.moved_by END
		FROM cur c WHERE m.tenant_id = $1 AND m.msg_id = c.msg_id
		RETURNING c.is_src, m.received_at
	)
	SELECT received_at FROM upd WHERE is_src`

func (s *Postgres) DemoteTopic(ctx context.Context, tenant, srcMsgID string, msgIDs []string) error {
	if !canonUUIDRe.MatchString(srcMsgID) {
		return ErrNotFound
	}
	ids := make([]string, 0, len(msgIDs))
	for _, id := range msgIDs {
		if canonUUIDRe.MatchString(id) {
			ids = append(ids, id)
		}
	}
	return s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `UPDATE messages SET
				task_id        = moved_from_task,
				parent_task_id = moved_from_parent,
				channel        = CASE WHEN moved_at IS NOT NULL AND moved_from_channel IS NOT NULL THEN moved_from_channel ELSE channel END,
				moved_at = NULL, moved_by = NULL, moved_from_channel = NULL,
				moved_from_task = NULL, moved_from_parent = NULL
			WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[]) AND moved_from_task IS NOT NULL`,
			tenant, ids); err != nil {
			return err
		}
		_, err := tx.Exec(ctx, `UPDATE messages SET is_parent = 0 WHERE tenant_id = $1 AND msg_id = $2::uuid`,
			tenant, srcMsgID)
		return err
	})
}

package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of specs/045 (message_move.go, rdb 0069). Every statement
// runs in the tenant scope. The mark follows markRow exactly:
//
//	moved_from_channel  COALESCE(moved_from_channel, channel) BEFORE the write
//	                    (the first move keeps the home)
//	moved_at / by       every move
//	cleared             when the row is back in its home channel and has no
//	                    home task left (clearHome)

func (s *Postgres) TaskCard(ctx context.Context, tenant, task string, now time.Time) (TaskCard, error) {
	if !canonUUIDRe.MatchString(task) {
		return TaskCard{}, ErrNotFound
	}
	var c TaskCard
	var channel *string
	// The card is the EARLIEST is_parent=1 row, not the earliest row overall
	// (CLE-35107, and the merge that demotes an older opener into this task,
	// 714c7028): a topic whose oldest row is a reply or a merged-in message
	// still resolves its card. prd t1 control e802196b.
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT m.msg_id::text, m.channel, m.received_at,
				EXISTS (SELECT 1 FROM issues i WHERE i.tenant_id = m.tenant_id AND i.task_id = m.task_id)
			FROM messages m
			WHERE m.tenant_id = $1 AND m.task_id = $2::uuid AND m.expires_at > $3 AND m.is_parent = 1
			ORDER BY m.received_at, m.msg_id LIMIT 1`, tenant, task, now).
			Scan(&c.MsgID, &channel, &c.ReceivedAt, &c.IssueTopic)
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return TaskCard{}, ErrNotFound
	}
	if err != nil {
		return TaskCard{}, err
	}
	c.Channel = deref(channel)
	return c, nil
}

// clearHome drops the mark of every row of ids that is back home.
const clearHome = `UPDATE messages SET moved_at = NULL, moved_by = NULL, moved_from_channel = NULL
	WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[]) AND moved_at IS NOT NULL
	  AND moved_from_task IS NULL AND channel IS NOT DISTINCT FROM moved_from_channel`

// markTx re-channels ids and marks them (the channel half of markRow).
func markTx(ctx context.Context, tx pgx.Tx, tenant string, ids []string, toChannel, by string, at time.Time) error {
	_, err := tx.Exec(ctx, `UPDATE messages SET
			moved_from_channel = CASE WHEN moved_at IS NULL THEN channel ELSE moved_from_channel END,
			channel = $3, moved_at = $4, moved_by = $5
		WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[])`, tenant, ids, toChannel, at, by)
	return err
}

// movedTx answers whether msgID still carries a mark, and its received_at.
func movedTx(ctx context.Context, tx pgx.Tx, tenant, msgID string) (bool, time.Time, error) {
	var moved bool
	var at time.Time
	err := tx.QueryRow(ctx, `SELECT moved_at IS NOT NULL, received_at FROM messages
		WHERE tenant_id = $1 AND msg_id = $2`, tenant, msgID).Scan(&moved, &at)
	return moved, at, err
}

func (s *Postgres) MoveTopic(ctx context.Context, tenant, msgID, ownTask, toChannel, by string, at time.Time) (MoveResult, error) {
	if !canonUUIDRe.MatchString(msgID) || (ownTask != "" && !canonUUIDRe.MatchString(ownTask)) {
		return MoveResult{}, ErrNotFound
	}
	var res MoveResult
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		set, err := topicTx(ctx, tx, tenant, msgID, ownTask)
		if err != nil {
			return err
		}
		if err = markTx(ctx, tx, tenant, set.MsgIDs, toChannel, by, at); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, clearHome, tenant, set.MsgIDs); err != nil {
			return err
		}
		res.MsgIDs, res.TaskIDs = set.MsgIDs, set.TaskIDs
		res.Moved, res.ReceivedAt, err = movedTx(ctx, tx, tenant, msgID)
		return err
	})
	if err != nil {
		return MoveResult{}, err
	}
	return res, nil
}

func (s *Postgres) MoveMessage(ctx context.Context, tenant, msgID, toTask, toChannel, by string, at, notBefore time.Time) (MoveResult, error) {
	if !canonUUIDRe.MatchString(msgID) || !canonUUIDRe.MatchString(toTask) {
		return MoveResult{}, ErrNotFound
	}
	var res MoveResult
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		set, err := topicTx(ctx, tx, tenant, msgID, "") // locks the row FOR UPDATE
		if err != nil {
			return err
		}
		for _, t := range set.TaskIDs {
			if t == toTask {
				return ErrMoveCycle
			}
		}
		res.MsgIDs, res.TaskIDs = set.MsgIDs, set.TaskIDs
		err = tx.QueryRow(ctx, moveMessageCTE, tenant, msgID, set.MsgIDs, toTask, toChannel, notBefore, at, by).
			Scan(&res.Moved, &res.ReceivedAt)
		return err
	})
	if err != nil {
		return MoveResult{}, err
	}
	return res, nil
}

// moveMessageCTE is MoveMessage's write in ONE statement (perf round 4 G5):
// the old read -> 5 UPDATEs -> movedTx chain, each stage a column of b..d read
// from the row as it was, so every row is written once. Stages, as before:
//
//	home      the moved row ($2) records its home task/parent on its first
//	          message move, then is re-homed into $4 (not a parent, received_at
//	          not before $6)
//	mark      every row of the topic ($3) -> channel $5 (markTx)
//	back      the moved row landed in its home task: home parent restored
//	repoint   a thread row whose parent was the old task now points at $4
//	clear     a row back home with no home task left drops its mark (clearHome)
//
// cur holds every row FOR UPDATE (the moved row is already held by topicTx),
// so the stages read the rows the UPDATE writes.
const moveMessageCTE = `WITH cur AS (
		SELECT msg_id, msg_id = $2::uuid AS is_m, task_id, parent_task_id, moved_at, moved_from_task, moved_from_parent,
			moved_from_channel, channel
		FROM messages WHERE tenant_id = $1 AND msg_id = ANY($3::uuid[])
		FOR UPDATE
	), b AS (
		SELECT cur.*, (SELECT task_id FROM cur WHERE is_m) AS from_task,
			CASE WHEN is_m AND (moved_at IS NULL OR moved_from_task IS NULL) THEN task_id ELSE moved_from_task END AS mft,
			CASE WHEN is_m AND (moved_at IS NULL OR moved_from_task IS NULL) THEN parent_task_id ELSE moved_from_parent END AS mfp,
			CASE WHEN moved_at IS NULL THEN channel ELSE moved_from_channel END AS mfc
		FROM cur
	), c AS (
		SELECT b.*, is_m AND mft = $4::uuid AS back FROM b
	), d AS (
		SELECT c.*, (CASE WHEN back THEN NULL ELSE mft END) IS NULL AND $5::text IS NOT DISTINCT FROM mfc AS clear FROM c
	), upd AS (
		UPDATE messages m SET
			task_id           = CASE WHEN d.is_m THEN $4::uuid ELSE m.task_id END,
			is_parent         = CASE WHEN d.is_m THEN 0 ELSE m.is_parent END,
			received_at       = CASE WHEN d.is_m THEN GREATEST(m.received_at, $6::timestamptz) ELSE m.received_at END,
			parent_task_id    = CASE WHEN d.back THEN d.mfp WHEN d.is_m THEN NULL
				WHEN m.parent_task_id = d.from_task THEN $4::uuid ELSE m.parent_task_id END,
			moved_from_task   = CASE WHEN d.back THEN NULL ELSE d.mft END,
			moved_from_parent = CASE WHEN d.back THEN NULL ELSE d.mfp END,
			channel = $5,
			moved_from_channel = CASE WHEN d.clear THEN NULL ELSE d.mfc END,
			moved_at           = CASE WHEN d.clear THEN NULL ELSE $7::timestamptz END,
			moved_by           = CASE WHEN d.clear THEN NULL ELSE $8::text END
		FROM d WHERE m.tenant_id = $1 AND m.msg_id = d.msg_id
		RETURNING d.is_m, m.moved_at IS NOT NULL AS moved, m.received_at
	)
	SELECT moved, received_at FROM upd WHERE is_m`

// MovedTaskChannel probes messages_moved (only moved rows): one index probe on
// the send path, spec 045 §3.7.
func (s *Postgres) MovedTaskChannel(ctx context.Context, tenant, task string) (string, bool, error) {
	if !canonUUIDRe.MatchString(task) {
		return "", false, nil
	}
	var channel *string
	err := s.queryRowTenant(ctx, tenant, `SELECT channel FROM messages
		WHERE tenant_id = $1 AND task_id = $2::uuid AND moved_at IS NOT NULL
		ORDER BY received_at, msg_id LIMIT 1`, []any{tenant, task}, &channel)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", false, nil
	}
	if err != nil {
		return "", false, err
	}
	return deref(channel), true, nil
}

// scanMove fills a view row's mark from the six columns the view reads.
func scanMove(v *MoveMark, at *time.Time, by, fromChannel, fromTask, channel, task, parent *string) {
	if at == nil {
		return
	}
	*v = MoveMark{At: *at, By: deref(by), FromChannel: deref(fromChannel), FromTask: deref(fromTask),
		Channel: deref(channel), TaskID: deref(task), ParentTaskID: deref(parent)}
}

// moveCols is the column list scanMove reads, for a view SELECT whose
// messages table is aliased p ("" = not aliased).
func moveCols(p string) string {
	if p != "" {
		p += "."
	}
	return p + "moved_at, " + p + "moved_by, " + p + "moved_from_channel, " + p + "moved_from_task::text, " +
		p + "channel, " + p + "task_id::text, " + p + "parent_task_id::text"
}

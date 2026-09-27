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
	var isParent int
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT m.msg_id::text, m.channel, m.received_at, m.is_parent,
				EXISTS (SELECT 1 FROM issues i WHERE i.tenant_id = m.tenant_id AND i.task_id = m.task_id)
			FROM messages m
			WHERE m.tenant_id = $1 AND m.task_id = $2::uuid AND m.expires_at > $3
			ORDER BY m.received_at, m.msg_id LIMIT 1`, tenant, task, now).
			Scan(&c.MsgID, &channel, &c.ReceivedAt, &isParent, &c.IssueTopic)
	})
	if errors.Is(err, pgx.ErrNoRows) || (err == nil && isParent != 1) {
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
		var from string
		if err = tx.QueryRow(ctx, `SELECT task_id::text FROM messages WHERE tenant_id = $1 AND msg_id = $2`,
			tenant, msgID).Scan(&from); err != nil {
			return err
		}
		// The row: record its home task on the first message move, re-home
		// it, and restore the home parent when it lands back in its home task.
		if _, err = tx.Exec(ctx, `UPDATE messages SET
				moved_from_task   = CASE WHEN moved_at IS NULL OR moved_from_task IS NULL THEN task_id ELSE moved_from_task END,
				moved_from_parent = CASE WHEN moved_at IS NULL OR moved_from_task IS NULL THEN parent_task_id ELSE moved_from_parent END
			WHERE tenant_id = $1 AND msg_id = $2`, tenant, msgID); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `UPDATE messages SET task_id = $3::uuid, parent_task_id = NULL, is_parent = 0,
				received_at = GREATEST(received_at, $4)
			WHERE tenant_id = $1 AND msg_id = $2`, tenant, msgID, toTask, notBefore); err != nil {
			return err
		}
		if err = markTx(ctx, tx, tenant, set.MsgIDs, toChannel, by, at); err != nil {
			return err
		}
		if _, err = tx.Exec(ctx, `UPDATE messages SET parent_task_id = moved_from_parent,
				moved_from_task = NULL, moved_from_parent = NULL
			WHERE tenant_id = $1 AND msg_id = $2 AND task_id = moved_from_task`, tenant, msgID); err != nil {
			return err
		}
		// Its thread: a parent that pointed at the old topic now points at
		// the new one, so a delete of the old topic does not take it.
		if len(set.MsgIDs) > 1 {
			if _, err = tx.Exec(ctx, `UPDATE messages SET parent_task_id = $3::uuid
				WHERE tenant_id = $1 AND msg_id = ANY($2::uuid[]) AND parent_task_id = $4::uuid`,
				tenant, set.MsgIDs[1:], toTask, from); err != nil {
				return err
			}
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

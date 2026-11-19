package store

import (
	"context"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of topic_pause.go (rdb 0297, spec 179 row B1). Every read
// and write runs in the workspace's own scope (rdb 0297's tenant_scope
// policy); the change_stamp trigger moves the tenant's stamp on a pause and
// a resume.

// SetTopicPaused implements TopicPauseStore: the row and the issues in one
// transaction.
func (s *Postgres) SetTopicPaused(ctx context.Context, tenant, taskID, by, reason string, at time.Time, paused bool) (TopicPauseState, error) {
	key, reason, err := checkTopicPause(tenant, taskID, by, reason)
	if err != nil {
		return TopicPauseState{}, err
	}
	at = followAt(at)
	var st TopicPauseState
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		if !paused {
			st, err = topicResumeTx(ctx, tx, tenant, key, by, at)
			return err
		}
		if st.Pause, st.Changed, err = topicPauseRowTx(ctx, tx, tenant, key, by, reason, at); err != nil || !st.Changed {
			return err
		}
		st.Followed, err = followQuery(ctx, tx, IssueFollowPause, `WITH hit AS (`+issueFollowHit+`),
			rec AS (INSERT INTO topic_pause_issues (tenant_id, number, task_id, prev_status, paused_at, paused_by)
				SELECT $1, hit.number, hit.task::uuid, hit.status, $4, left($5, 64) FROM hit
				ON CONFLICT (tenant_id, number) DO UPDATE SET task_id = EXCLUDED.task_id,
					prev_status = EXCLUDED.prev_status, paused_at = EXCLUDED.paused_at, paused_by = EXCLUDED.paused_by)
			UPDATE issues i SET status = 'onhold', updated_at = $4, updated_by = left($5, 64)
			FROM hit WHERE i.tenant_id = $1 AND i.number = hit.number
			RETURNING i.number, hit.task, hit.status, 'onhold'`,
			tenant, []string{key}, TopicPauseHold, at, by)
		return err
	})
	if err != nil {
		return TopicPauseState{}, mapFK(err)
	}
	return st, nil
}

// topicPauseRowTx writes the pause row: a new one (Changed), or on a repeat
// only a new non-empty reason (Changed false, no stamp move when nothing
// differs). It answers the row after it.
func topicPauseRowTx(ctx context.Context, tx pgx.Tx, tenant, key, by, reason string, at time.Time) (TopicPause, bool, error) {
	p := TopicPause{TenantID: tenant}
	err := tx.QueryRow(ctx, `INSERT INTO topic_pauses (tenant_id, task_id, paused_by, paused_at, reason)
		VALUES ($1, $2, $3, $4, $5) ON CONFLICT (tenant_id, task_id) DO NOTHING
		RETURNING task_id::text, paused_by, paused_at, reason`,
		tenant, key, by, at, reason).Scan(&p.TaskID, &p.PausedBy, &p.PausedAt, &p.Reason)
	if err == nil {
		p.PausedAt = p.PausedAt.UTC()
		return p, true, nil
	}
	if !errors.Is(err, pgx.ErrNoRows) {
		return TopicPause{}, false, err
	}
	err = tx.QueryRow(ctx, `WITH up AS (UPDATE topic_pauses SET reason = $3
			WHERE tenant_id = $1 AND task_id = $2 AND $3 <> '' AND reason <> $3
			RETURNING task_id, paused_by, paused_at, reason)
		SELECT task_id::text, paused_by, paused_at, reason FROM up
		UNION ALL
		SELECT task_id::text, paused_by, paused_at, reason FROM topic_pauses
		WHERE tenant_id = $1 AND task_id = $2 AND NOT EXISTS (SELECT 1 FROM up)`,
		tenant, key, reason).Scan(&p.TaskID, &p.PausedBy, &p.PausedAt, &p.Reason)
	p.PausedAt = p.PausedAt.UTC()
	return p, false, err
}

// topicResumeTx drops the pause row and restores every issue the pause
// held that is still onhold (spec 179 4.2 step 1, followUnarchiveTx's
// shape). Every held row of the topic is dropped, restored or not.
func topicResumeTx(ctx context.Context, tx pgx.Tx, tenant, key, by string, at time.Time) (TopicPauseState, error) {
	var st TopicPauseState
	tag, err := tx.Exec(ctx, `DELETE FROM topic_pauses WHERE tenant_id = $1 AND task_id = $2`, tenant, key)
	if err != nil {
		return st, err
	}
	st.Changed = tag.RowsAffected() == 1
	st.Followed, err = followQuery(ctx, tx, IssueFollowResume, `WITH back AS (
			DELETE FROM topic_pause_issues p
			WHERE p.tenant_id = $1 AND p.task_id = ANY($2::uuid[])
			RETURNING p.number, p.task_id::text AS task, p.prev_status)
		UPDATE issues i SET status = CASE WHEN back.prev_status = 'wip' THEN 'todo' ELSE back.prev_status END,
			updated_at = $3, updated_by = left($4, 64)
		FROM back WHERE i.tenant_id = $1 AND i.number = back.number AND i.status = 'onhold'
			AND i.deleted_at IS NULL AND i.archived_at IS NULL
		RETURNING i.number, back.task, 'onhold', i.status`,
		tenant, []string{key}, at, by)
	return st, err
}

// AnyTopicPaused implements TopicPauseStore: one probe of the primary key.
func (s *Postgres) AnyTopicPaused(ctx context.Context, tenant string, taskIDs ...string) (TopicPause, bool, error) {
	if err := checkTenant(tenant); err != nil {
		return TopicPause{}, false, err
	}
	keys := topicPauseKeys(taskIDs)
	if len(keys) == 0 {
		return TopicPause{}, false, nil
	}
	p := TopicPause{TenantID: tenant}
	err := s.queryRowTenant(ctx, tenant, `SELECT task_id::text, paused_by, paused_at, reason FROM topic_pauses
		WHERE tenant_id = $1 AND task_id = ANY ($2::uuid[]) ORDER BY array_position($2::uuid[], task_id) LIMIT 1`,
		[]any{tenant, keys}, &p.TaskID, &p.PausedBy, &p.PausedAt, &p.Reason)
	if errors.Is(err, pgx.ErrNoRows) {
		return TopicPause{}, false, nil
	}
	if err != nil {
		return TopicPause{}, false, err
	}
	p.PausedAt = p.PausedAt.UTC()
	return p, true, nil
}

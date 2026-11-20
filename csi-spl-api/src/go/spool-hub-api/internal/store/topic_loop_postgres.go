package store

import (
	"context"
	"errors"
	"strings"
	"time"

	"github.com/jackc/pgx/v5"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Postgres side of topic_loop.go (rdb 0299, spec 182 row L1). Every read and
// write runs in the workspace's own scope (rdb 0299's tenant_scope policy),
// except ClaimDueTopicLoops, the ticker's claim over every workspace; the
// change_stamp trigger moves the tenant's stamp on each write.

// topicLoopCols are the columns scanTopicLoop reads, in its order.
const topicLoopCols = `tenant_id, loop_id::text, task_id::text, prompt, triggers, set_by, set_at, state,
	hour_start, fires_in_hour, fires_total, last_fired_at, coalesce(interval_min, 0), next_due_at, awaiting, awaiting_until,
	coalesce(keyword, ''), coalesce(idle_min, 0), idle_due_at, coalesce(idle_post::text, ''),
	coalesce(to_char(daily_at, 'HH24:MI'), ''), daily_tz, daily_due_at`

// topicLoopRowCols are the table columns topicLoopCols reads, by name: what an
// UPDATE ... RETURNING hands on to a SELECT of topicLoopCols.
const topicLoopRowCols = `tenant_id, loop_id, task_id, prompt, triggers, set_by, set_at, state,
	hour_start, fires_in_hour, fires_total, last_fired_at, interval_min, next_due_at, awaiting, awaiting_until,
	keyword, idle_min, idle_due_at, idle_post, daily_at, daily_tz, daily_due_at`

// scanTopicLoop reads one topicLoopCols row, after any lead columns.
func scanTopicLoop(row pgx.Row, lead ...any) (TopicLoop, error) {
	var l TopicLoop
	var hour, last, due, until, idle, daily *time.Time
	if err := row.Scan(append(lead, &l.TenantID, &l.LoopID, &l.TaskID, &l.Prompt, &l.Triggers, &l.SetBy, &l.SetAt, &l.State,
		&hour, &l.FiresInHour, &l.FiresTotal, &last, &l.IntervalMin, &due, &l.Awaiting, &until,
		&l.Keyword, &l.IdleMin, &idle, &l.IdlePost, &l.DailyAt, &l.DailyTZ, &daily)...); err != nil {
		return TopicLoop{}, err
	}
	l.SetAt = l.SetAt.UTC()
	l.HourStart, l.LastFiredAt, l.NextDueAt, l.AwaitUntil = utcOrZero(hour), utcOrZero(last), utcOrZero(due), utcOrZero(until)
	l.IdleDueAt, l.DailyDueAt = utcOrZero(idle), utcOrZero(daily)
	return l, nil
}

// nullInterval is n, NULL when 0.
func nullInterval(n int) any {
	if n == 0 {
		return nil
	}
	return n
}

// topicLoopFieldArgs are the v0.4 field columns of l in topicLoopFieldCols
// order, NULL when unset.
func topicLoopFieldArgs(l TopicLoop) []any {
	return []any{nullInterval(l.IntervalMin), nullTime(l.NextDueAt), nullText(l.Keyword), nullInterval(l.IdleMin),
		nullTime(l.IdleDueAt), nullText(l.IdlePost), nullText(l.DailyAt), l.DailyTZ, nullTime(l.DailyDueAt)}
}

// topicLoopFieldCols are topicLoopFieldArgs' columns.
const topicLoopFieldCols = `interval_min, next_due_at, keyword, idle_min, idle_due_at, idle_post, daily_at, daily_tz, daily_due_at`

// TopicLoops implements TopicLoopStore.
func (s *Postgres) TopicLoops(ctx context.Context, tenant, taskID string) ([]TopicLoop, error) {
	return s.topicLoops(ctx, tenant, taskID, "")
}

// TopicLoopsOn implements TopicLoopStore.
func (s *Postgres) TopicLoopsOn(ctx context.Context, tenant, taskID string) ([]TopicLoop, error) {
	return s.topicLoops(ctx, tenant, taskID, " AND state = 'on'")
}

// topicLoops is taskID's loops passing and: one probe of topic_loops_task.
func (s *Postgres) topicLoops(ctx context.Context, tenant, taskID, and string) ([]TopicLoop, error) {
	key, err := checkTopicLoopTask(tenant, taskID)
	if err != nil {
		return nil, err
	}
	var out []TopicLoop
	err = s.queryTenant(ctx, tenant, `SELECT `+topicLoopCols+` FROM topic_loops
		WHERE tenant_id = $1 AND task_id = $2`+and+` ORDER BY set_at, loop_id`, []any{tenant, key},
		func(rows pgx.Rows) error {
			l, err := scanTopicLoop(rows)
			out = append(out, l)
			return err
		})
	return out, err
}

// AddTopicLoop implements TopicLoopStore.
func (s *Postgres) AddTopicLoop(ctx context.Context, tenant string, l TopicLoop) (TopicLoop, error) {
	row, err := newTopicLoop(tenant, l)
	if err != nil {
		return TopicLoop{}, err
	}
	if row.LoopID == "" {
		row.LoopID = uuid.New()
	}
	var out TopicLoop
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		out, err = scanTopicLoop(tx.QueryRow(ctx, `INSERT INTO topic_loops
				(tenant_id, loop_id, task_id, prompt, triggers, set_by, set_at, state, `+topicLoopFieldCols+`)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14::uuid, $15::time, $16, $17)
			RETURNING `+topicLoopCols,
			append([]any{tenant, row.LoopID, row.TaskID, row.Prompt, row.Triggers, row.SetBy, row.SetAt, row.State},
				topicLoopFieldArgs(row)...)...))
		return err
	})
	if err != nil {
		return TopicLoop{}, mapFK(err)
	}
	return out, nil
}

// EditTopicLoop implements TopicLoopStore: the row is read FOR UPDATE, the
// edit applied by applyTopicLoopEdit (the rule Memory runs too) and written
// back, in one transaction.
func (s *Postgres) EditTopicLoop(ctx context.Context, tenant, taskID, loopID string, e TopicLoopEdit) (TopicLoop, error) {
	key, err := checkTopicLoopTask(tenant, taskID)
	if err != nil {
		return TopicLoop{}, err
	}
	if !isUUID(loopID) {
		return TopicLoop{}, ErrNotFound
	}
	var out TopicLoop
	err = s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		old, err := scanTopicLoop(tx.QueryRow(ctx, `SELECT `+topicLoopCols+` FROM topic_loops
			WHERE tenant_id = $1 AND task_id = $2 AND loop_id = $3 FOR UPDATE`, tenant, key, strings.ToLower(loopID)))
		if err != nil {
			return err
		}
		l, err := applyTopicLoopEdit(old, e)
		if err != nil {
			return err
		}
		out, err = scanTopicLoop(tx.QueryRow(ctx, `UPDATE topic_loops SET prompt = $3, triggers = $4, set_by = $5, set_at = $6,
				state = $7, hour_start = $8, fires_in_hour = $9, (`+topicLoopFieldCols+`) =
				ROW($10, $11, $12, $13, $14, $15::uuid, $16::time, $17, $18)
			WHERE tenant_id = $1 AND loop_id = $2 RETURNING `+topicLoopCols,
			append([]any{tenant, l.LoopID, l.Prompt, l.Triggers, l.SetBy, l.SetAt, l.State, nullTime(l.HourStart), l.FiresInHour},
				topicLoopFieldArgs(l)...)...))
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return TopicLoop{}, ErrNotFound
	}
	return out, err
}

// DeleteTopicLoop implements TopicLoopStore.
func (s *Postgres) DeleteTopicLoop(ctx context.Context, tenant, taskID, loopID string) (bool, error) {
	key, err := checkTopicLoopTask(tenant, taskID)
	if err != nil || !isUUID(loopID) {
		return false, err
	}
	tag, err := s.execTenant(ctx, tenant, `DELETE FROM topic_loops WHERE tenant_id = $1 AND task_id = $2 AND loop_id = $3`,
		tenant, key, strings.ToLower(loopID))
	return err == nil && tag.RowsAffected() == 1, err
}

// DeleteTopicLoops implements TopicLoopStore.
func (s *Postgres) DeleteTopicLoops(ctx context.Context, tenant, taskID string) (int, error) {
	key, err := checkTopicLoopTask(tenant, taskID)
	if err != nil {
		return 0, err
	}
	tag, err := s.execTenant(ctx, tenant, `DELETE FROM topic_loops WHERE tenant_id = $1 AND task_id = $2`, tenant, key)
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}

// topicLoopFireSQL is the cap check and the count in one statement (spec
// 182 5.1). A concurrent fire waits on the row lock and then re-checks the
// WHERE on the row the first one wrote (READ COMMITTED), so the cap holds
// across hub instances. $3 is the fire's clock, $4 the cap. The first
// column says whether it counted; without a count the row is read as it is.
const topicLoopFireSQL = `WITH fired AS (
		UPDATE topic_loops SET
			fires_in_hour = CASE WHEN hour_start IS NULL OR hour_start <= $3::timestamptz - interval '1 hour'
				THEN 1 ELSE fires_in_hour + 1 END,
			hour_start = CASE WHEN hour_start IS NULL OR hour_start <= $3::timestamptz - interval '1 hour'
				THEN $3::timestamptz ELSE hour_start END,
			fires_total = fires_total + 1, last_fired_at = $3::timestamptz
		WHERE tenant_id = $1 AND loop_id = $2 AND state = 'on'
			AND (hour_start IS NULL OR hour_start <= $3::timestamptz - interval '1 hour' OR fires_in_hour < $4)
		RETURNING ` + topicLoopRowCols + `)
	SELECT true, ` + topicLoopCols + ` FROM fired
	UNION ALL
	SELECT false, ` + topicLoopCols + ` FROM topic_loops
	WHERE tenant_id = $1 AND loop_id = $2 AND NOT EXISTS (SELECT 1 FROM fired)`

// CountTopicLoopFire implements TopicLoopStore.
func (s *Postgres) CountTopicLoopFire(ctx context.Context, tenant, loopID string, at time.Time, cap int) (TopicLoop, bool, error) {
	if err := checkTenant(tenant); err != nil {
		return TopicLoop{}, false, err
	}
	if !isUUID(loopID) {
		return TopicLoop{}, false, nil
	}
	var out TopicLoop
	var fired bool
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		var err error
		out, err = scanTopicLoop(tx.QueryRow(ctx, topicLoopFireSQL, tenant, strings.ToLower(loopID), followAt(at), topicLoopCap(cap)), &fired)
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return TopicLoop{}, false, nil
	}
	return out, fired, err
}

// topicLoopDailySQL is the first daily_at in daily_tz strictly after $1
// (the SQL twin of topicLoopNextDaily), on alias t.
const topicLoopDailySQL = `CASE WHEN (($1::timestamptz AT TIME ZONE t.daily_tz)::date + t.daily_at) AT TIME ZONE t.daily_tz > $1::timestamptz
		THEN (($1::timestamptz AT TIME ZONE t.daily_tz)::date + t.daily_at) AT TIME ZONE t.daily_tz
		ELSE (($1::timestamptz AT TIME ZONE t.daily_tz)::date + 1 + t.daily_at) AT TIME ZONE t.daily_tz END`

// topicLoopPeriodSQL is topicLoopPeriod in minutes on alias t (LEAST skips
// the NULL of a box not checked).
const topicLoopPeriodSQL = `LEAST(CASE WHEN 'every_hour' = ANY (t.triggers) THEN 60 END,
		CASE WHEN 'every_n_minutes' = ANY (t.triggers) THEN t.interval_min END)`

// topicLoopClaimSQL is the ticker's claim (spec 182 4.2 step 5): the on
// loops of every workspace with a due time <= $1, earliest first (the
// topic_loops_due index), locked with SKIP LOCKED so a second hub instance
// claims others or none. In the same statement each due time moves from
// $1: next_due_at by the period, daily_due_at to the next daily_at, the
// idle count to NULL. due keeps the old values, so the two lead columns are
// the keys that came due (topicLoopClaim's order), the old idle_post and
// DueAt (v0.5: the earliest pre-move next_due_at or daily_due_at that came
// due; least() skips the NULL of one that did not).
var topicLoopClaimSQL = `WITH due AS (
		SELECT tenant_id, loop_id, next_due_at, idle_due_at, idle_post, daily_due_at FROM topic_loops
		WHERE state = 'on' AND least(next_due_at, idle_due_at, daily_due_at) <= $1
		ORDER BY least(next_due_at, idle_due_at, daily_due_at), tenant_id, loop_id LIMIT $2 FOR UPDATE SKIP LOCKED)
	UPDATE topic_loops t SET
		next_due_at = CASE WHEN due.next_due_at <= $1 THEN $1::timestamptz + make_interval(mins => ` + topicLoopPeriodSQL + `)
			ELSE t.next_due_at END,
		idle_due_at = CASE WHEN due.idle_due_at <= $1 THEN NULL ELSE t.idle_due_at END,
		idle_post = CASE WHEN due.idle_due_at <= $1 THEN NULL ELSE t.idle_post END,
		daily_due_at = CASE WHEN due.daily_due_at <= $1 THEN ` + topicLoopDailySQL + ` ELSE t.daily_due_at END
	FROM due WHERE t.tenant_id = due.tenant_id AND t.loop_id = due.loop_id
	RETURNING array_remove(ARRAY[
			CASE WHEN due.next_due_at <= $1 AND 'every_hour' = ANY (t.triggers) AND ` + topicLoopPeriodSQL + ` = 60 THEN 'every_hour' END,
			CASE WHEN due.next_due_at <= $1 AND 'every_n_minutes' = ANY (t.triggers) AND ` + topicLoopPeriodSQL + ` = t.interval_min
				THEN 'every_n_minutes' END,
			CASE WHEN due.idle_due_at <= $1 THEN 'no_reply_after_human' END,
			CASE WHEN due.daily_due_at <= $1 THEN 'daily_at' END], NULL),
		coalesce(due.idle_post::text, ''),
		least(CASE WHEN due.next_due_at <= $1 THEN due.next_due_at END, CASE WHEN due.daily_due_at <= $1 THEN due.daily_due_at END),
		` + topicLoopColsT

// topicLoopColsT is topicLoopCols on alias t (due has tenant_id and
// loop_id too).
const topicLoopColsT = `t.tenant_id, t.loop_id::text, t.task_id::text, t.prompt, t.triggers, t.set_by, t.set_at, t.state,
	t.hour_start, t.fires_in_hour, t.fires_total, t.last_fired_at, coalesce(t.interval_min, 0), t.next_due_at, t.awaiting, t.awaiting_until,
	coalesce(t.keyword, ''), coalesce(t.idle_min, 0), t.idle_due_at, coalesce(t.idle_post::text, ''),
	coalesce(to_char(t.daily_at, 'HH24:MI'), ''), t.daily_tz, t.daily_due_at`

// ClaimDueTopicLoops implements TopicLoopStore, in the operator scope: the
// ticker serves every workspace.
func (s *Postgres) ClaimDueTopicLoops(ctx context.Context, at time.Time, limit int) ([]TopicLoop, error) {
	if limit <= 0 {
		limit = topicLoopClaimDefault
	}
	var out []TopicLoop
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, topicLoopClaimSQL, followAt(at), limit)
		if err != nil {
			return err
		}
		return scanRows(rows, func(rows pgx.Rows) error {
			var due []string
			var post string
			var dueAt *time.Time
			l, err := scanTopicLoop(rows, &due, &post, &dueAt)
			l.Due, l.IdlePost, l.DueAt = due, post, utcOrZero(dueAt)
			out = append(out, l)
			return err
		})
	})
	if err != nil {
		return nil, err
	}
	sortTopicLoopsDue(out)
	return out, nil
}

// ArmTopicLoopIdle implements TopicLoopStore: one UPDATE of the topic's on
// loops with no_reply_after_human.
func (s *Postgres) ArmTopicLoopIdle(ctx context.Context, tenant, taskID, postID string, at time.Time) (int, error) {
	key, err := checkTopicLoopTask(tenant, taskID)
	if err != nil {
		return 0, err
	}
	if !isUUID(postID) {
		return 0, ErrBadTopicLoop
	}
	tag, err := s.execTenant(ctx, tenant, `UPDATE topic_loops
		SET idle_due_at = $4::timestamptz + make_interval(mins => idle_min), idle_post = $3
		WHERE tenant_id = $1 AND task_id = $2 AND state = 'on' AND 'no_reply_after_human' = ANY (triggers)`,
		tenant, key, strings.ToLower(postID), followAt(at))
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}

// ClearTopicLoopIdle implements TopicLoopStore: only the armed loops are
// written, so an agent reply in a topic with none moves no stamp.
func (s *Postgres) ClearTopicLoopIdle(ctx context.Context, tenant, taskID string) (int, error) {
	key, err := checkTopicLoopTask(tenant, taskID)
	if err != nil {
		return 0, err
	}
	tag, err := s.execTenant(ctx, tenant, `UPDATE topic_loops SET idle_due_at = NULL, idle_post = NULL
		WHERE tenant_id = $1 AND task_id = $2 AND (idle_due_at IS NOT NULL OR idle_post IS NOT NULL)`, tenant, key)
	if err != nil {
		return 0, err
	}
	return int(tag.RowsAffected()), nil
}

// SetTopicLoopAwaiting implements TopicLoopStore.
func (s *Postgres) SetTopicLoopAwaiting(ctx context.Context, tenant, loopID, agent string, until time.Time) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if len(agent) > 64 {
		return ErrBadTopicLoop
	}
	if !isUUID(loopID) {
		return ErrNotFound
	}
	var due any
	if agent != "" && !until.IsZero() {
		due = followAt(until)
	}
	tag, err := s.execTenant(ctx, tenant, `UPDATE topic_loops SET awaiting = $3, awaiting_until = $4
		WHERE tenant_id = $1 AND loop_id = $2`, tenant, strings.ToLower(loopID), agent, due)
	if err == nil && tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return err
}

// TenantHasTopicLoops implements TopicLoopStore: one index probe.
func (s *Postgres) TenantHasTopicLoops(ctx context.Context, tenant string) (bool, error) {
	if err := checkTenant(tenant); err != nil {
		return false, err
	}
	var ok bool
	err := s.queryRowTenant(ctx, tenant, `SELECT EXISTS (SELECT 1 FROM topic_loops WHERE tenant_id = $1)`, []any{tenant}, &ok)
	return ok, err
}

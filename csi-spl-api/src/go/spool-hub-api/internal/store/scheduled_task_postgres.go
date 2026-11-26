package store

import (
	"context"
	"encoding/json"
	"errors"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of scheduled_task.go (rdb 0331, spec 187 row S1). A
// workspace's rows are read and written in its own scope (rdb 0331's
// tenant_scope policy); an instance task (tenant "") only in the operator
// scope, which is also where the ticker's claim, the event lookup (it adds
// the instance's event tasks) and the instance's run count run. No
// change_stamp trigger: no view reads these tables.

// taskCols are the columns scanTask reads, in its order.
const taskCols = `coalesce(tenant_id, ''), task_id::text, level, name, owner_id, template, scope_object, scope_where,
	scope_query, max_objects, trigger_kind, trigger_spec, tz, action_kind, action_spec, state, paused_reason,
	next_due_at, fail_streak, instance_tenants, created_by, created_at, updated_at`

// scanTask reads one taskCols row.
func scanTask(row pgx.Row) (ScheduledTask, error) {
	var t ScheduledTask
	var trig, act []byte
	var due *time.Time
	if err := row.Scan(&t.TenantID, &t.TaskID, &t.Level, &t.Name, &t.OwnerID, &t.Template, &t.ScopeObject, &t.ScopeWhere,
		&t.ScopeQuery, &t.MaxObjects, &t.TriggerKind, &trig, &t.TZ, &t.ActionKind, &act, &t.State, &t.PausedReason,
		&due, &t.FailStreak, &t.InstanceTenants, &t.CreatedBy, &t.CreatedAt, &t.UpdatedAt); err != nil {
		return ScheduledTask{}, err
	}
	if err := json.Unmarshal(trig, &t.Trigger); err != nil {
		return ScheduledTask{}, err
	}
	if err := json.Unmarshal(act, &t.Action); err != nil {
		return ScheduledTask{}, err
	}
	t.NextDueAt, t.CreatedAt, t.UpdatedAt = utcOrZero(due), t.CreatedAt.UTC(), t.UpdatedAt.UTC()
	return t, nil
}

// taskArgs are t's columns after tenant_id and task_id, in taskWriteCols order.
func taskArgs(t ScheduledTask) ([]any, error) {
	trig, err := json.Marshal(t.Trigger)
	if err != nil {
		return nil, err
	}
	act, err := json.Marshal(t.Action)
	if err != nil {
		return nil, err
	}
	return []any{t.Level, t.Name, t.OwnerID, t.Template, t.ScopeObject, t.ScopeWhere, t.ScopeQuery, t.MaxObjects,
		t.TriggerKind, string(trig), t.TZ, t.ActionKind, string(act), t.State, t.PausedReason, nullTime(t.NextDueAt),
		t.FailStreak, t.InstanceTenants, t.UpdatedAt}, nil
}

// taskWriteCols are taskArgs' columns.
const taskWriteCols = `level, name, owner_id, template, scope_object, scope_where, scope_query, max_objects,
	trigger_kind, trigger_spec, tz, action_kind, action_spec, state, paused_reason, next_due_at,
	fail_streak, instance_tenants, updated_at`

// taskScope runs fn in tenant's scope, or in the operator scope for the
// instance's tasks (tenant ""), which no tenant scope can see (rdb 0331).
func (s *Postgres) taskScope(ctx context.Context, tenant string, fn func(pgx.Tx) error) error {
	if tenant == "" {
		return s.asOperator(ctx, fn)
	}
	return s.inTenant(ctx, tenant, fn)
}

// CreateTask implements ScheduledTaskStore.
func (s *Postgres) CreateTask(ctx context.Context, t ScheduledTask) (ScheduledTask, error) {
	row, err := newTask(t)
	if err != nil {
		return ScheduledTask{}, err
	}
	args, err := taskArgs(row)
	if err != nil {
		return ScheduledTask{}, err
	}
	var out ScheduledTask
	err = s.taskScope(ctx, row.TenantID, func(tx pgx.Tx) error {
		out, err = scanTask(tx.QueryRow(ctx, `INSERT INTO scheduled_tasks
				(tenant_id, task_id, created_by, created_at, `+taskWriteCols+`)
			VALUES (NULLIF($1, ''), $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14::jsonb, $15, $16, $17::jsonb,
				$18, $19, $20, $21, $22, $23)
			RETURNING `+taskCols,
			append([]any{row.TenantID, row.TaskID, row.CreatedBy, row.CreatedAt}, args...)...))
		return err
	})
	if isUniqueViolation(err) {
		return ScheduledTask{}, ErrConflict
	}
	if err != nil {
		return ScheduledTask{}, mapFK(err)
	}
	return out, nil
}

// UpdateTask implements ScheduledTaskStore: the row is read FOR UPDATE, the
// update applied by applyTaskUpdate (the rule Memory runs too) and written
// back, in one transaction.
func (s *Postgres) UpdateTask(ctx context.Context, t ScheduledTask) (ScheduledTask, error) {
	key, err := checkTaskKey(t.TaskID)
	if err != nil {
		return ScheduledTask{}, err
	}
	var out ScheduledTask
	err = s.taskScope(ctx, t.TenantID, func(tx pgx.Tx) error {
		old, err := scanTask(tx.QueryRow(ctx, `SELECT `+taskCols+` FROM scheduled_tasks
			WHERE task_id = $1 AND tenant_id IS NOT DISTINCT FROM NULLIF($2, '') FOR UPDATE`, key, t.TenantID))
		if err != nil {
			return err
		}
		row, err := applyTaskUpdate(old, t)
		if err != nil {
			return err
		}
		args, err := taskArgs(row)
		if err != nil {
			return err
		}
		out, err = scanTask(tx.QueryRow(ctx, `UPDATE scheduled_tasks SET (`+taskWriteCols+`) =
				ROW($2, $3, $4, $5, $6, $7, $8, $9, $10, $11::jsonb, $12, $13, $14::jsonb, $15, $16, $17, $18, $19, $20)
			WHERE task_id = $1 RETURNING `+taskCols, append([]any{key}, args...)...))
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return ScheduledTask{}, ErrNotFound
	}
	return out, err
}

// SetTaskState implements ScheduledTaskStore.
func (s *Postgres) SetTaskState(ctx context.Context, tenant, taskID, state, reason string, at time.Time) error {
	if err := checkStateChange(state, reason); err != nil {
		return err
	}
	key, err := checkTaskKey(taskID)
	if err != nil {
		return err
	}
	var n int64
	err = s.taskScope(ctx, tenant, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `UPDATE scheduled_tasks SET state = $3, paused_reason = $4, next_due_at = NULL,
				updated_at = $5, deleted_at = CASE WHEN $3 = 'deleted' THEN $5 ELSE deleted_at END
			WHERE task_id = $1 AND tenant_id IS NOT DISTINCT FROM NULLIF($2, '')`, key, tenant, state, reason, followAt(at))
		n = tag.RowsAffected()
		return err
	})
	if err == nil && n == 0 {
		return ErrNotFound
	}
	return err
}

// GetTask implements ScheduledTaskStore.
func (s *Postgres) GetTask(ctx context.Context, tenant, taskID string) (ScheduledTask, error) {
	key, err := checkTaskKey(taskID)
	if err != nil {
		return ScheduledTask{}, err
	}
	var out ScheduledTask
	err = s.taskScope(ctx, tenant, func(tx pgx.Tx) error {
		out, err = scanTask(tx.QueryRow(ctx, `SELECT `+taskCols+` FROM scheduled_tasks
			WHERE task_id = $1 AND tenant_id IS NOT DISTINCT FROM NULLIF($2, '')`, key, tenant))
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return ScheduledTask{}, ErrNotFound
	}
	return out, err
}

// ListTasks implements ScheduledTaskStore: one probe of scheduled_tasks_tenant
// (for the instance, a scan of its few NULL-tenant rows).
func (s *Postgres) ListTasks(ctx context.Context, tenant string) ([]ScheduledTask, error) {
	var out []ScheduledTask
	err := s.taskScope(ctx, tenant, func(tx pgx.Tx) error {
		return eachRow(ctx, tx, `SELECT `+taskCols+` FROM scheduled_tasks
			WHERE tenant_id IS NOT DISTINCT FROM NULLIF($1, '') AND state <> 'deleted' ORDER BY created_at, task_id`,
			[]any{tenant}, func(rows pgx.Rows) error {
				t, err := scanTask(rows)
				out = append(out, t)
				return err
			})
	})
	return out, err
}

// taskClaimSQL is the ticker's claim (spec 187 8.2 step 1): the on tasks of
// every workspace and the instance whose next_due_at is <= $1, earliest
// first (the scheduled_tasks_due index), locked with SKIP LOCKED so a second
// hub instance claims others or none. The move to next(task) is the UPDATE
// that follows in the same transaction: a claimer that reads after the
// commit sees the moved time, which the due filter then refuses.
const taskClaimSQL = `SELECT ` + taskCols + ` FROM scheduled_tasks
	WHERE state = 'on' AND next_due_at <= $1
	ORDER BY next_due_at, task_id LIMIT $2 FOR UPDATE SKIP LOCKED`

// ClaimDueTasks implements ScheduledTaskStore, in the operator scope: the
// ticker serves every workspace and the instance.
func (s *Postgres) ClaimDueTasks(ctx context.Context, now time.Time, next func(ScheduledTask) time.Time, limit int) ([]ScheduledTask, error) {
	if limit <= 0 {
		limit = taskListDefault
	}
	var out []ScheduledTask
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		out = nil
		if err := eachRow(ctx, tx, taskClaimSQL, []any{followAt(now), limit}, func(rows pgx.Rows) error {
			t, err := scanTask(rows)
			out = append(out, t)
			return err
		}); err != nil || len(out) == 0 {
			return err
		}
		ids, dues := make([]string, len(out)), make([]*time.Time, len(out))
		for i, t := range out {
			ids[i], dues[i] = t.TaskID, nullTime(taskNextDue(next, taskCopy(t)))
		}
		_, err := tx.Exec(ctx, `UPDATE scheduled_tasks t SET next_due_at = u.due
			FROM unnest($1::uuid[], $2::timestamptz[]) AS u (id, due) WHERE t.task_id = u.id`, ids, dues)
		return err
	})
	if err != nil {
		return nil, err
	}
	return out, nil
}

// EventTasks implements ScheduledTaskStore, in the operator scope: the
// tenant's own event tasks (the scheduled_tasks_event index) and the
// instance's that run in it, which its own scope cannot see.
func (s *Postgres) EventTasks(ctx context.Context, tenant, object string) ([]ScheduledTask, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	var out []ScheduledTask
	err := s.asOperatorQuery(ctx, `SELECT `+taskCols+` FROM scheduled_tasks
		WHERE state = 'on' AND trigger_kind = 'event' AND scope_object = $2
			AND (tenant_id = $1 OR (tenant_id IS NULL AND (cardinality(instance_tenants) = 0 OR $1 = ANY (instance_tenants))))
		ORDER BY created_at, task_id`, []any{tenant, object}, func(rows pgx.Rows) error {
		t, err := scanTask(rows)
		out = append(out, t)
		return err
	})
	return out, err
}

// runCols are the columns scanRun reads, in its order.
const runCols = `tenant_id, run_id::text, task_id::text, level, cause, chain::text[], started_at, ended_at, outcome,
	matched, acted, failures, error, tokens, agent_id, coalesce(result_msg_id::text, '')`

// scanRun reads one runCols row.
func scanRun(row pgx.Row) (TaskRun, error) {
	var r TaskRun
	var ended *time.Time
	var fails []byte
	if err := row.Scan(&r.TenantID, &r.RunID, &r.TaskID, &r.Level, &r.Cause, &r.Chain, &r.StartedAt, &ended, &r.Outcome,
		&r.Matched, &r.Acted, &fails, &r.Error, &r.Tokens, &r.AgentID, &r.ResultMsgID); err != nil {
		return TaskRun{}, err
	}
	if err := json.Unmarshal(fails, &r.Failures); err != nil {
		return TaskRun{}, err
	}
	r.StartedAt, r.EndedAt = r.StartedAt.UTC(), utcOrZero(ended)
	return r, nil
}

// StartRun implements ScheduledTaskStore: an insert that a second claim of
// the same cause turns into nothing (8.2 step 3).
func (s *Postgres) StartRun(ctx context.Context, r TaskRun) (bool, error) {
	row, err := normRun(r)
	if err != nil {
		return false, err
	}
	fails, err := json.Marshal(nonNilFailures(row.Failures))
	if err != nil {
		return false, err
	}
	tag, err := s.execTenant(ctx, row.TenantID, `INSERT INTO scheduled_task_runs (tenant_id, run_id, task_id, level, cause,
			chain, started_at, ended_at, outcome, matched, acted, failures, error, tokens, agent_id, result_msg_id)
		VALUES ($1, $2, $3, $4, $5, $6::uuid[], $7, $8, $9, $10, $11, $12::jsonb, $13, $14, $15, NULLIF($16, '')::uuid)
		ON CONFLICT (tenant_id, run_id) DO NOTHING`,
		row.TenantID, row.RunID, row.TaskID, row.Level, row.Cause, row.Chain, row.StartedAt, nullTime(row.EndedAt),
		row.Outcome, row.Matched, row.Acted, string(fails), row.Error, row.Tokens, row.AgentID, row.ResultMsgID)
	if err != nil {
		return false, mapFK(err)
	}
	return tag.RowsAffected() == 1, nil
}

// nonNilFailures is fs, or an empty list (jsonb '[]', never null).
func nonNilFailures(fs []TaskRunFailure) []TaskRunFailure {
	if fs == nil {
		return []TaskRunFailure{}
	}
	return fs
}

// FinishRun implements ScheduledTaskStore.
func (s *Postgres) FinishRun(ctx context.Context, r TaskRun) error {
	row, err := finishedRun(r)
	if err != nil {
		return err
	}
	fails, err := json.Marshal(row.Failures)
	if err != nil {
		return err
	}
	tag, err := s.execTenant(ctx, row.TenantID, `UPDATE scheduled_task_runs SET ended_at = $3, outcome = $4, matched = $5,
			acted = $6, failures = $7::jsonb, error = $8, tokens = $9, agent_id = $10, result_msg_id = NULLIF($11, '')::uuid
		WHERE tenant_id = $1 AND run_id = $2`, row.TenantID, row.RunID, row.EndedAt, row.Outcome, row.Matched, row.Acted,
		string(fails), row.Error, row.Tokens, row.AgentID, row.ResultMsgID)
	if err == nil && tag.RowsAffected() == 0 {
		return ErrNotFound
	}
	return err
}

// ListRuns implements ScheduledTaskStore: one probe of scheduled_task_runs_task.
func (s *Postgres) ListRuns(ctx context.Context, tenant, taskID string, limit int) ([]TaskRun, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	key, err := checkTaskKey(taskID)
	if err != nil {
		return nil, nil
	}
	if limit <= 0 {
		limit = taskListDefault
	}
	var out []TaskRun
	err = s.queryTenant(ctx, tenant, `SELECT `+runCols+` FROM scheduled_task_runs
		WHERE tenant_id = $1 AND task_id = $2 ORDER BY started_at DESC, run_id LIMIT $3`, []any{tenant, key, limit},
		func(rows pgx.Rows) error {
			r, err := scanRun(rows)
			out = append(out, r)
			return err
		})
	return out, err
}

// taskRunsSinceSQL counts the runs of one level since $2 that count towards
// a cap (taskRunCounted); $1 is the tenant, or NULL for every tenant.
const taskRunsSinceSQL = `SELECT count(*) FROM scheduled_task_runs
	WHERE ($1::text IS NULL OR tenant_id = $1) AND level = $3 AND started_at >= $2
		AND NOT (outcome = 'skipped' AND (error LIKE 'chain\_self%' OR error LIKE 'chain\_depth%'))`

// RunsSince implements ScheduledTaskStore: a workspace's count in its own
// scope, the instance's over every workspace in the operator scope (D16).
func (s *Postgres) RunsSince(ctx context.Context, tenant, level string, since time.Time) (int, error) {
	if err := checkRunsSince(tenant, level); err != nil {
		return 0, err
	}
	var n int
	err := s.taskScope(ctx, tenant, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, taskRunsSinceSQL, nullText(tenant), since.UTC(), level).Scan(&n)
	})
	return n, err
}

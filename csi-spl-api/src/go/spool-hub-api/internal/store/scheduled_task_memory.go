package store

import (
	"context"
	"slices"
	"sort"
	"time"
)

// Memory side of scheduled_task.go (rdb 0331, spec 187 row S1). The rows
// live beside the Memory value, as memTopicLoops does, under s.mu. Each rule
// is the shared one of scheduled_task.go (newTask, applyTaskUpdate,
// taskEventMatch, normRun, finishedRun, taskRunCounted), so the two stores
// cannot drift.

// memTasks is one Memory store's scheduled_tasks, task id -> row (task ids
// are unique hub-wide, rdb 0331's primary key).
var memTasks = map[*Memory]map[string]ScheduledTask{}

// memTaskRuns is one Memory store's scheduled_task_runs, (tenant, run id) -> row.
var memTaskRuns = map[*Memory]map[[2]string]TaskRun{}

// tasksLocked is s's task rows, made on first use. The caller holds s.mu.
func (s *Memory) tasksLocked() map[string]ScheduledTask {
	if memTasks[s] == nil {
		memTasks[s] = map[string]ScheduledTask{}
	}
	return memTasks[s]
}

// taskRunsLocked is s's run rows, made on first use. The caller holds s.mu.
func (s *Memory) taskRunsLocked() map[[2]string]TaskRun {
	if memTaskRuns[s] == nil {
		memTaskRuns[s] = map[[2]string]TaskRun{}
	}
	return memTaskRuns[s]
}

// taskCopy is t with its own slices, so a caller cannot write the stored
// row through them.
func taskCopy(t ScheduledTask) ScheduledTask {
	t.ScopeWhere, t.InstanceTenants = slices.Clone(t.ScopeWhere), slices.Clone(t.InstanceTenants)
	t.Trigger.Weekdays, t.Action.Mention = slices.Clone(t.Trigger.Weekdays), slices.Clone(t.Action.Mention)
	return t
}

// runCopy is r with its own slices.
func runCopy(r TaskRun) TaskRun {
	r.Chain, r.Failures = slices.Clone(r.Chain), slices.Clone(r.Failures)
	return r
}

// sortTasks orders ts by CreatedAt, then TaskID.
func sortTasks(ts []ScheduledTask) {
	sort.Slice(ts, func(i, j int) bool {
		if !ts[i].CreatedAt.Equal(ts[j].CreatedAt) {
			return ts[i].CreatedAt.Before(ts[j].CreatedAt)
		}
		return ts[i].TaskID < ts[j].TaskID
	})
}

// memTaskTenant reports whether tenant is "" (the instance) or a known
// workspace. The caller holds s.mu.
func (s *Memory) memTaskTenant(tenant string) bool {
	_, ok := s.tenants[tenant]
	return tenant == "" || ok
}

// CreateTask implements ScheduledTaskStore.
func (s *Memory) CreateTask(_ context.Context, t ScheduledTask) (ScheduledTask, error) {
	row, err := newTask(t)
	if err != nil {
		return ScheduledTask{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if !s.memTaskTenant(row.TenantID) {
		return ScheduledTask{}, ErrNotFound
	}
	tl := s.tasksLocked()
	if _, dup := tl[row.TaskID]; dup {
		return ScheduledTask{}, ErrConflict
	}
	tl[row.TaskID] = taskCopy(row)
	return taskCopy(row), nil
}

// memTaskOf is the row of (tenant, taskID), the way a tenant scope sees it.
// The caller holds s.mu.
func (s *Memory) memTaskOf(tenant, taskID string) (ScheduledTask, bool) {
	key, err := checkTaskKey(taskID)
	if err != nil {
		return ScheduledTask{}, false
	}
	t, ok := s.tasksLocked()[key]
	return t, ok && t.TenantID == tenant
}

// UpdateTask implements ScheduledTaskStore.
func (s *Memory) UpdateTask(_ context.Context, t ScheduledTask) (ScheduledTask, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	old, ok := s.memTaskOf(t.TenantID, t.TaskID)
	if !ok {
		return ScheduledTask{}, ErrNotFound
	}
	row, err := applyTaskUpdate(old, t)
	if err != nil {
		return ScheduledTask{}, err
	}
	s.tasksLocked()[row.TaskID] = taskCopy(row)
	return taskCopy(row), nil
}

// SetTaskState implements ScheduledTaskStore.
func (s *Memory) SetTaskState(_ context.Context, tenant, taskID, state, reason string, at time.Time) error {
	if err := checkStateChange(state, reason); err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.memTaskOf(tenant, taskID)
	if !ok {
		return ErrNotFound
	}
	t.State, t.PausedReason, t.NextDueAt, t.UpdatedAt = state, reason, time.Time{}, followAt(at)
	s.tasksLocked()[t.TaskID] = t
	return nil
}

// GetTask implements ScheduledTaskStore.
func (s *Memory) GetTask(_ context.Context, tenant, taskID string) (ScheduledTask, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	t, ok := s.memTaskOf(tenant, taskID)
	if !ok {
		return ScheduledTask{}, ErrNotFound
	}
	return taskCopy(t), nil
}

// ListTasks implements ScheduledTaskStore.
func (s *Memory) ListTasks(_ context.Context, tenant string) ([]ScheduledTask, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []ScheduledTask
	for _, t := range s.tasksLocked() {
		if t.TenantID == tenant && t.State != TaskDeleted {
			out = append(out, taskCopy(t))
		}
	}
	sortTasks(out)
	return out, nil
}

// ClaimDueTasks implements ScheduledTaskStore: under s.mu, so one claimer
// moves a due task before another can read it.
func (s *Memory) ClaimDueTasks(_ context.Context, now time.Time, next func(ScheduledTask) time.Time, limit int) ([]ScheduledTask, error) {
	if limit <= 0 {
		limit = taskListDefault
	}
	at := followAt(now)
	s.mu.Lock()
	defer s.mu.Unlock()
	var due []ScheduledTask
	for _, t := range s.tasksLocked() {
		if t.State == TaskOn && !t.NextDueAt.IsZero() && !t.NextDueAt.After(at) {
			due = append(due, t)
		}
	}
	sortTasksDue(due)
	if len(due) > limit {
		due = due[:limit]
	}
	tl := s.tasksLocked()
	for i, t := range due {
		moved := t
		moved.NextDueAt = taskNextDue(next, taskCopy(t))
		tl[t.TaskID] = moved
		due[i] = taskCopy(t)
	}
	return due, nil
}

// sortTasksDue orders claimed tasks earliest due first, then by task id.
func sortTasksDue(ts []ScheduledTask) {
	sort.Slice(ts, func(i, j int) bool {
		if !ts[i].NextDueAt.Equal(ts[j].NextDueAt) {
			return ts[i].NextDueAt.Before(ts[j].NextDueAt)
		}
		return ts[i].TaskID < ts[j].TaskID
	})
}

// taskNextDue is next(t) as stored: UTC at microseconds, zero for none.
func taskNextDue(next func(ScheduledTask) time.Time, t ScheduledTask) time.Time {
	if next == nil {
		return time.Time{}
	}
	n := next(t)
	if n.IsZero() {
		return n
	}
	return followAt(n)
}

// EventTasks implements ScheduledTaskStore.
func (s *Memory) EventTasks(_ context.Context, tenant, object string) ([]ScheduledTask, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []ScheduledTask
	for _, t := range s.tasksLocked() {
		if taskEventMatch(t, tenant, object) {
			out = append(out, taskCopy(t))
		}
	}
	sortTasks(out)
	return out, nil
}

// StartRun implements ScheduledTaskStore.
func (s *Memory) StartRun(_ context.Context, r TaskRun) (bool, error) {
	row, err := normRun(r)
	if err != nil {
		return false, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, ok := s.tenants[row.TenantID]; !ok {
		return false, ErrNotFound
	}
	rl := s.taskRunsLocked()
	k := [2]string{row.TenantID, row.RunID}
	if _, dup := rl[k]; dup {
		return false, nil
	}
	if row.Failures == nil {
		row.Failures = []TaskRunFailure{}
	}
	rl[k] = runCopy(row)
	return true, nil
}

// FinishRun implements ScheduledTaskStore.
func (s *Memory) FinishRun(_ context.Context, r TaskRun) error {
	row, err := finishedRun(r)
	if err != nil {
		return err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	rl := s.taskRunsLocked()
	k := [2]string{row.TenantID, row.RunID}
	old, ok := rl[k]
	if !ok {
		return ErrNotFound
	}
	old.EndedAt, old.Outcome, old.Matched, old.Acted = row.EndedAt, row.Outcome, row.Matched, row.Acted
	old.Failures, old.Error, old.Tokens, old.AgentID, old.ResultMsgID = row.Failures, row.Error, row.Tokens, row.AgentID, row.ResultMsgID
	rl[k] = runCopy(old)
	return nil
}

// ListRuns implements ScheduledTaskStore.
func (s *Memory) ListRuns(_ context.Context, tenant, taskID string, limit int) ([]TaskRun, error) {
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
	s.mu.Lock()
	defer s.mu.Unlock()
	var out []TaskRun
	for k, r := range s.taskRunsLocked() {
		if k[0] == tenant && r.TaskID == key {
			out = append(out, runCopy(r))
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].StartedAt.Equal(out[j].StartedAt) {
			return out[i].StartedAt.After(out[j].StartedAt)
		}
		return out[i].RunID < out[j].RunID
	})
	if len(out) > limit {
		out = out[:limit]
	}
	return out, nil
}

// RunsSince implements ScheduledTaskStore.
func (s *Memory) RunsSince(_ context.Context, tenant, level string, since time.Time) (int, error) {
	if err := checkRunsSince(tenant, level); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	n := 0
	for k, r := range s.taskRunsLocked() {
		if (tenant == "" || k[0] == tenant) && r.Level == level && !r.StartedAt.Before(since) && taskRunCounted(r) {
			n++
		}
	}
	return n, nil
}

package store

import (
	"context"
	"encoding/json"
	"errors"
	"slices"
	"strings"
	"time"
	"unicode/utf8"

	guuid "github.com/google/uuid"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Scheduled tasks and activities (spec 187 v0.7 sections 4, 5, 8.1 and the
// binding contract 9.1.1, row S1, rdb 0331). The owner (HUM-10, t1
// 91992830): a task picks objects of a workspace (4.1), runs on a schedule
// or an event (4.2) and acts on them (4.3); each run is a scheduled_task_runs
// row (4.6). An instance task (D4, D10) has no workspace: it is stored with
// TenantID "" and read and written only in the operator scope.
//
// The store keeps the rows and their CHECKs; when a task runs, who may write
// it and what its run does are the hub's (rows S3 to S7).

// A task's level, its states and the limits of 8.1 (rdb 0331's CHECKs).
const (
	TaskLevelWorkspace        = "workspace"
	TaskLevelInstance         = "instance"
	TaskOn                    = "on"
	TaskPaused                = "paused"
	TaskDeleted               = "deleted"
	TaskMaxObjects            = 500
	TaskPromptMax             = 4000   // characters
	TaskNameMax               = 120    // characters
	TaskWhereMax              = 50     // channel ids
	TaskIntervalMax           = 10080  // minutes; the floor is the instance's tasks.min_interval_min
	TaskCronMax               = 64     // characters (4.2.1)
	TaskChainMax              = 3      // D15: tasks deep; tasks.max_chain_depth may only lower it
	TaskRunsPerDayDefault     = 50     // D18
	TaskTokensPerMonthDefault = 500000 // D18
)

// The values rdb 0331's CHECKs allow for scope_object, trigger_kind,
// action_kind, trigger_spec.on, a run's outcome and paused_reason.
var (
	TaskObjects      = []string{"channel", "topic", "message", "issue"}
	TaskTriggers     = []string{"once", "every_n_minutes", "daily", "weekly", "monthly", "cron", "event"}
	TaskActions      = []string{"move", "archive", "label", "set_priority", "notify", "agent"}
	TaskEvents       = []string{"message_new", "topic_new", "issue_new", "issue_changed"}
	TaskOutcomes     = []string{"running", "ok", "partial", "failed", "skipped"}
	TaskPauseReasons = []string{"", "by_person", "done", "owner_left", "failing", "cap"}
)

// Run errors with a fixed meaning (TaskRun.Error starts with one of them).
var TaskRunErrors = []string{"chain_self", "chain_depth", "no_agent", "no_answer", "token_quota", "cap"}

// taskTemplates are rdb 0331's template CHECK (spec 187 7).
var taskTemplates = []string{"", "channel_digest", "stale_issues", "idle_topics", "weekly_status"}

// ErrBadTask: a value outside the CHECKs of 8.1, a zone time.LoadLocation
// refuses, a cron expression 4.2.1 refuses, or a trigger or action spec
// that does not fit its kind. Before any write.
var ErrBadTask = errors.New("store: bad scheduled task")

// ScheduledTask is a scheduled_tasks row (8.1).
type ScheduledTask struct {
	TenantID        string // "" = instance task
	TaskID          string // uuid, lower case
	Level           string
	Name            string
	OwnerID         string // member id, or HUB-0 for an instance task
	Template        string
	ScopeObject     string
	ScopeWhere      []string // empty = all channels
	ScopeQuery      string
	MaxObjects      int
	TriggerKind     string
	Trigger         TaskTriggerSpec
	TZ              string // IANA; "" read and written as "UTC"
	ActionKind      string
	Action          TaskActionSpec
	State           string
	PausedReason    string
	NextDueAt       time.Time // zero: event task, or paused
	FailStreak      int
	InstanceTenants []string // instance task: empty = every workspace
	CreatedBy       string
	CreatedAt       time.Time
	UpdatedAt       time.Time
}

// TaskTriggerSpec is trigger_spec; only the fields of its kind are set.
type TaskTriggerSpec struct {
	At          time.Time `json:"at,omitempty"`           // once
	IntervalMin int       `json:"interval_min,omitempty"` // every_n_minutes
	AtTime      string    `json:"at_time,omitempty"`      // "hh:mm": daily, weekly, monthly
	Weekdays    []int     `json:"weekdays,omitempty"`     // 1..7 = Mon..Sun: weekly
	MonthDay    int       `json:"month_day,omitempty"`    // 1..28; 0 = last: monthly
	Cron        string    `json:"cron,omitempty"`         // cron: 5 fields, 4.2.1 (0..7 = Sun..Sun)
	On          string    `json:"on,omitempty"`           // event: one of TaskEvents
}

// TaskActionSpec is action_spec; only the fields of its kind are set.
type TaskActionSpec struct {
	Channel         string   `json:"channel,omitempty"`          // move
	Label           string   `json:"label,omitempty"`            // label: an issue_labels.label_id (issue, topic, message; D19)
	Priority        int      `json:"priority,omitempty"`         // set_priority
	Mention         []string `json:"mention,omitempty"`          // notify: member ids
	MentionAssignee bool     `json:"mention_assignee,omitempty"` // notify (D22): also each matched object's assignee (4.3)
	Prompt          string   `json:"prompt,omitempty"`           // agent
	Agent           string   `json:"agent,omitempty"`            // agent (D11): the named agent; offline -> any online agent of the workspace
}

// TaskRun is a scheduled_task_runs row (4.6).
type TaskRun struct {
	TenantID    string
	RunID       string // UUIDv5(task_id, cause)
	TaskID      string
	Level       string   // the task's level (D16)
	Cause       string   // RFC 3339 due time, or the object's id
	Chain       []string // D15: task ids that led here, oldest first; len <= TaskChainMax
	StartedAt   time.Time
	EndedAt     time.Time // zero while running
	Outcome     string
	Matched     int
	Acted       int
	Failures    []TaskRunFailure
	Error       string
	Tokens      int64
	AgentID     string // D11: who ran an agent run
	ResultMsgID string
}

// TaskRunFailure is one object a run could not act on, and why.
type TaskRunFailure struct {
	Object string `json:"object"`
	Reason string `json:"reason"`
}

// ScheduledTaskStore keeps the tasks, their runs and hub_settings; the
// shared rules of both stores follow it.
type ScheduledTaskStore interface {
	CreateTask(ctx context.Context, t ScheduledTask) (ScheduledTask, error)
	UpdateTask(ctx context.Context, t ScheduledTask) (ScheduledTask, error) // by (TenantID, TaskID)
	SetTaskState(ctx context.Context, tenant, taskID, state, reason string, at time.Time) error
	GetTask(ctx context.Context, tenant, taskID string) (ScheduledTask, error)
	ListTasks(ctx context.Context, tenant string) ([]ScheduledTask, error) // "" = instance tasks
	// ClaimDueTasks moves next_due_at of each due task to next(task) in the
	// claiming statement and returns the tasks as they were before the move.
	ClaimDueTasks(ctx context.Context, now time.Time, next func(ScheduledTask) time.Time, limit int) ([]ScheduledTask, error)
	EventTasks(ctx context.Context, tenant, object string) ([]ScheduledTask, error)
	StartRun(ctx context.Context, r TaskRun) (bool, error) // false: the run_id exists
	FinishRun(ctx context.Context, r TaskRun) error
	ListRuns(ctx context.Context, tenant, taskID string, limit int) ([]TaskRun, error)
	// RunsSince counts runs of one level: a workspace's own (level
	// "workspace", tenant set) or the instance's over every tenant
	// (level "instance", tenant ""), D16. Chain-refused runs are not counted.
	RunsSince(ctx context.Context, tenant, level string, since time.Time) (int, error)
	HubSetting(ctx context.Context, key string) (json.RawMessage, bool, error)
	SetHubSetting(ctx context.Context, key string, v json.RawMessage, by string, at time.Time) error
}

var (
	_ ScheduledTaskStore = (*Memory)(nil)
	_ ScheduledTaskStore = (*Postgres)(nil)
)

// Further rules both stores share, beyond the contract's comments:
//   - CreateTask mints TaskID with uid.New when "", sets State on when "",
//     MaxObjects 100 when 0, TZ UTC when "", and CreatedAt = UpdatedAt =
//     t.CreatedAt (now when zero). TenantID "" is an instance task (Level
//     must say so); a workspace task has no InstanceTenants.
//   - UpdateTask writes every field but TenantID, TaskID, Level, CreatedBy
//     and CreatedAt, with UpdatedAt = t.UpdatedAt (now when zero);
//     ErrNotFound for a missing or deleted task.
//   - SetTaskState: on takes reason ""; paused one of TaskPauseReasons but
//     ""; deleted takes "" and stamps deleted_at. Every change of state
//     clears next_due_at: the hub sets the next due time of a resumed task
//     with UpdateTask (4.4: from now, no catch-up). ErrNotFound when gone.
//   - GetTask returns a deleted task too; ListTasks leaves them out, and
//     orders by CreatedAt then TaskID.
//   - ClaimDueTasks takes state-on tasks of every workspace and the
//     instance with next_due_at <= now, earliest first; a zero next(t)
//     stores NULL (a once task that ran).
//   - EventTasks: the tenant's state-on event tasks of object plus the
//     instance's ones that run in tenant, CreatedAt then TaskID.
//   - StartRun sets RunID = TaskRunID(TaskID, Cause), Outcome running when
//     "", StartedAt now when zero, Level workspace when "". FinishRun
//     writes the result fields by (TenantID, RunID), EndedAt now when zero,
//     and cuts Error to 500 characters; ErrNotFound when the run is gone.
//   - ListRuns: newest StartedAt first, at most limit (100 when <= 0).

// TaskRunID is a run's id: UUIDv5 of the cause in the task id's namespace
// (spec 187 4.6), so a second claim of one cause is the same row.
func TaskRunID(taskID, cause string) string {
	ns, err := guuid.Parse(taskID)
	if err != nil {
		return ""
	}
	return guuid.NewSHA1(ns, []byte(cause)).String()
}

// taskListDefault is ListRuns' limit when none is given.
const taskListDefault = 100

// taskRunErrorMax is the run error's length (rdb 0331 CHECK).
const taskRunErrorMax = 500

// capRunError is e cut to taskRunErrorMax runes: rdb 0331 counts characters,
// and every run write (StartRun, FinishRun) cuts, never refuses.
func capRunError(e string) string {
	if utf8.RuneCountInString(e) <= taskRunErrorMax {
		return e
	}
	return string([]rune(e)[:taskRunErrorMax])
}

// taskChainRefused are the run errors that count towards no cap (5.3 item 4).
var taskChainRefused = []string{"chain_self", "chain_depth"}

// taskIDLen is the longest member, owner, agent or by id rdb 0331 takes.
const taskIDLen = 64

// runeLen reports s has 1..max characters.
func runeLen(s string, max int) bool {
	n := utf8.RuneCountInString(s)
	return n >= 1 && n <= max
}

// checkTaskTenant validates the pair as stored: TenantID "" is exactly an
// instance task.
func checkTaskTenant(t ScheduledTask) bool {
	if t.TenantID == "" {
		return t.Level == TaskLevelInstance
	}
	return t.Level == TaskLevelWorkspace && len(t.InstanceTenants) == 0
}

// normTask is t as rdb 0331 stores it, or ErrBadTask.
func normTask(t ScheduledTask) (ScheduledTask, error) {
	t.TaskID, t.Name = strings.ToLower(t.TaskID), strings.TrimSpace(t.Name)
	if t.TZ == "" {
		t.TZ = topicLoopUTC
	}
	if t.ScopeWhere == nil {
		t.ScopeWhere = []string{}
	}
	if t.InstanceTenants == nil {
		t.InstanceTenants = []string{}
	}
	ok := isUUID(t.TaskID) && checkTaskTenant(t) && runeLen(t.Name, TaskNameMax) &&
		runeLen(t.OwnerID, taskIDLen) && t.CreatedBy != "" &&
		slices.Contains(taskTemplates, t.Template) && slices.Contains(TaskObjects, t.ScopeObject) &&
		checkTaskWhere(t.ScopeWhere) && utf8.RuneCountInString(t.ScopeQuery) <= 1024 &&
		t.MaxObjects >= 1 && t.MaxObjects <= TaskMaxObjects && t.FailStreak >= 0 &&
		checkTaskState(t.State, t.PausedReason) && checkTaskZone(t.TZ) &&
		checkTaskTrigger(t.TriggerKind, t.Trigger) && checkTaskAction(t.ActionKind, t.Action)
	if !ok {
		return ScheduledTask{}, ErrBadTask
	}
	return t, nil
}

// checkTaskWhere: at most TaskWhereMax distinct channel slugs.
func checkTaskWhere(where []string) bool {
	if len(where) > TaskWhereMax {
		return false
	}
	for i, ch := range where {
		if !ValidChannelID(ch) || slices.Contains(where[:i], ch) {
			return false
		}
	}
	return true
}

// checkTaskState: a known state, and a reason exactly when paused.
func checkTaskState(state, reason string) bool {
	switch state {
	case TaskOn, TaskDeleted:
		return reason == ""
	case TaskPaused:
		return reason != "" && slices.Contains(TaskPauseReasons, reason)
	}
	return false
}

// checkTaskZone: a zone time.LoadLocation knows, not "Local".
func checkTaskZone(tz string) bool {
	_, ok := topicLoopZone(tz)
	return ok && len(tz) <= 64
}

// checkTaskTrigger: the kind is one of TaskTriggers and its spec sets
// exactly that kind's fields. cron is refused until row S12b wires
// taskcron.Parse here (plan 3.1: "a stub that refuses trigger_kind = cron").
func checkTaskTrigger(kind string, s TaskTriggerSpec) bool {
	set := map[string]bool{"once": !s.At.IsZero(), "every_n_minutes": s.IntervalMin != 0,
		"clock": s.AtTime != "", "weekly": len(s.Weekdays) != 0, "monthly": s.MonthDay != 0,
		"cron": s.Cron != "", "event": s.On != ""}
	want := map[string][]string{"once": {"once"}, "every_n_minutes": {"every_n_minutes"}, "daily": {"clock"},
		"weekly": {"clock", "weekly"}, "monthly": {"clock", "monthly"}, "event": {"event"}}
	keys, ok := want[kind]
	if !ok {
		return false
	}
	for k, on := range set {
		if on && !slices.Contains(keys, k) {
			return false
		}
	}
	switch kind {
	case "once":
		return set["once"]
	case "every_n_minutes":
		return s.IntervalMin >= 1 && s.IntervalMin <= TaskIntervalMax
	case "event":
		return slices.Contains(TaskEvents, s.On)
	}
	return topicLoopClock(s.AtTime) && checkTaskDays(kind, s)
}

// checkTaskDays: weekly names 1..7 distinct weekdays, monthly a day 0..28.
func checkTaskDays(kind string, s TaskTriggerSpec) bool {
	switch kind {
	case "weekly":
		for i, d := range s.Weekdays {
			if d < 1 || d > 7 || slices.Contains(s.Weekdays[:i], d) {
				return false
			}
		}
		return len(s.Weekdays) > 0
	case "monthly":
		return s.MonthDay >= 0 && s.MonthDay <= 28
	}
	return true
}

// checkTaskAction: the kind is one of TaskActions and its spec sets exactly
// that kind's fields, each in its range.
func checkTaskAction(kind string, a TaskActionSpec) bool {
	set := map[string]bool{"move": a.Channel != "", "label": a.Label != "", "set_priority": a.Priority != 0,
		"notify": len(a.Mention) != 0 || a.MentionAssignee, "agent": a.Prompt != "" || a.Agent != ""}
	if !slices.Contains(TaskActions, kind) {
		return false
	}
	for k, on := range set {
		if on && k != kind {
			return false
		}
	}
	switch kind {
	case "move":
		return ValidChannelID(a.Channel)
	case "label":
		return runeLen(a.Label, taskIDLen)
	case "set_priority":
		return a.Priority >= 1 && a.Priority <= 5
	case "notify":
		return set["notify"] && checkTaskMentions(a.Mention)
	case "agent":
		return runeLen(strings.TrimSpace(a.Prompt), TaskPromptMax) && len(a.Agent) <= taskIDLen
	}
	return true
}

// checkTaskMentions: at most TaskWhereMax member ids of 1..64 characters.
func checkTaskMentions(ids []string) bool {
	if len(ids) > TaskWhereMax {
		return false
	}
	for _, id := range ids {
		if !runeLen(id, taskIDLen) {
			return false
		}
	}
	return true
}

// newTask is t checked for a create: the stored row, TaskID minted when "".
func newTask(t ScheduledTask) (ScheduledTask, error) {
	if t.State == "" {
		t.State = TaskOn
	}
	if t.MaxObjects == 0 {
		t.MaxObjects = 100
	}
	t.CreatedAt = followAt(t.CreatedAt)
	t.UpdatedAt = t.CreatedAt
	if !t.NextDueAt.IsZero() {
		t.NextDueAt = followAt(t.NextDueAt)
	}
	if t.TaskID == "" {
		t.TaskID = uuid.New()
	}
	return normTask(t)
}

// applyTaskUpdate is old with t's editable fields, checked; both stores
// write exactly this row.
func applyTaskUpdate(old, t ScheduledTask) (ScheduledTask, error) {
	if old.State == TaskDeleted {
		return ScheduledTask{}, ErrNotFound
	}
	t.TenantID, t.TaskID, t.Level, t.CreatedBy, t.CreatedAt = old.TenantID, old.TaskID, old.Level, old.CreatedBy, old.CreatedAt
	t.UpdatedAt = followAt(t.UpdatedAt)
	if !t.NextDueAt.IsZero() {
		t.NextDueAt = followAt(t.NextDueAt)
	}
	return normTask(t)
}

// checkTaskKey validates a (tenant, task) key: tenant "" is the instance.
func checkTaskKey(taskID string) (string, error) {
	if !isUUID(taskID) {
		return "", ErrNotFound
	}
	return strings.ToLower(taskID), nil
}

// taskEventMatch reports whether t is an event task of object that runs in
// tenant: the tenant's own, or an instance task listing it (or none).
func taskEventMatch(t ScheduledTask, tenant, object string) bool {
	if t.State != TaskOn || t.TriggerKind != "event" || t.ScopeObject != object {
		return false
	}
	if t.TenantID == "" {
		return len(t.InstanceTenants) == 0 || slices.Contains(t.InstanceTenants, tenant)
	}
	return t.TenantID == tenant
}

// normRun is r as StartRun stores it, or ErrBadTask.
func normRun(r TaskRun) (TaskRun, error) {
	if err := checkTenant(r.TenantID); err != nil {
		return TaskRun{}, err
	}
	r.TaskID = strings.ToLower(r.TaskID)
	r.RunID = TaskRunID(r.TaskID, r.Cause)
	if r.Outcome == "" {
		r.Outcome = "running"
	}
	if r.Level == "" {
		r.Level = TaskLevelWorkspace
	}
	r.StartedAt, r.Error = followAt(r.StartedAt), capRunError(r.Error)
	chain := make([]string, len(r.Chain))
	for i, c := range r.Chain {
		chain[i] = strings.ToLower(c)
	}
	r.Chain = chain
	if r.RunID == "" || !runeLen(r.Cause, 128) || len(r.Chain) > TaskChainMax || !checkTaskChain(r.Chain) ||
		(r.Level != TaskLevelWorkspace && r.Level != TaskLevelInstance) || !checkRunResult(r) {
		return TaskRun{}, ErrBadTask
	}
	return r, nil
}

// checkTaskChain: every id a uuid.
func checkTaskChain(chain []string) bool {
	for _, c := range chain {
		if !isUUID(c) {
			return false
		}
	}
	return true
}

// checkRunResult: the result fields in rdb 0331's ranges (Error is cut, not
// refused: a wrapped error may run long).
func checkRunResult(r TaskRun) bool {
	return slices.Contains(TaskOutcomes, r.Outcome) && r.Matched >= 0 && r.Acted >= 0 && r.Tokens >= 0 &&
		len(r.AgentID) <= taskIDLen && (r.ResultMsgID == "" || isUUID(r.ResultMsgID))
}

// finishedRun is r as FinishRun writes it, or ErrBadTask.
func finishedRun(r TaskRun) (TaskRun, error) {
	if err := checkTenant(r.TenantID); err != nil {
		return TaskRun{}, err
	}
	if !isUUID(r.RunID) || !checkRunResult(r) {
		return TaskRun{}, ErrBadTask
	}
	r.RunID, r.ResultMsgID = strings.ToLower(r.RunID), strings.ToLower(r.ResultMsgID)
	r.EndedAt = followAt(r.EndedAt)
	r.Error = capRunError(r.Error)
	if r.Failures == nil {
		r.Failures = []TaskRunFailure{}
	}
	return r, nil
}

// taskRunCounted reports whether r counts towards a cap (RunsSince): every
// run but a chain-refused skip.
func taskRunCounted(r TaskRun) bool {
	if r.Outcome != "skipped" {
		return true
	}
	for _, e := range taskChainRefused {
		if strings.HasPrefix(r.Error, e) {
			return false
		}
	}
	return true
}

// checkStateChange is SetTaskState's check of the new state and reason.
func checkStateChange(state, reason string) error {
	if !checkTaskState(state, reason) {
		return ErrBadTask
	}
	return nil
}

// checkRunsSince validates RunsSince's level and tenant pair.
func checkRunsSince(tenant, level string) error {
	switch {
	case level == TaskLevelWorkspace:
		return checkTenant(tenant)
	case level == TaskLevelInstance && tenant == "":
		return nil
	}
	return ErrBadTask
}

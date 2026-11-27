package store

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 187 v0.7 row S1 (rdb 0331): scheduled tasks, their runs, the hub
// settings and #scheduled-runs. Every test runs on Memory and, with
// SPOOL_TEST_PG_DSN, on Postgres with the same assertions (parity); the
// CHECK, RLS and migration tests are Postgres only.

// taskFix is one driver's workspace for a task test.
type taskFix struct {
	t   *testing.T
	ctx context.Context
	s   Store
	ts  ScheduledTaskStore
	tn  string
	t0  time.Time
}

func newTaskFix(t *testing.T, s Store) *taskFix {
	t.Helper()
	return &taskFix{t: t, ctx: context.Background(), s: s, ts: s.(ScheduledTaskStore), tn: newTenant(t, s),
		t0: time.Now().UTC().Truncate(time.Microsecond)}
}

// task is a valid daily workspace task of f's workspace, due at f.t0.
func (f *taskFix) task() ScheduledTask {
	return ScheduledTask{TenantID: f.tn, Level: TaskLevelWorkspace, Name: "nudge", OwnerID: "HUM-1",
		Template: "stale_issues", ScopeObject: "issue", ScopeQuery: "status:wip", TriggerKind: "daily",
		Trigger: TaskTriggerSpec{AtTime: "09:00"}, TZ: "Europe/Helsinki", ActionKind: "notify",
		Action: TaskActionSpec{MentionAssignee: true}, NextDueAt: f.t0, CreatedBy: "HUM-1", CreatedAt: f.t0}
}

// create stores t, failing the test on an error.
func (f *taskFix) create(t ScheduledTask) ScheduledTask {
	f.t.Helper()
	out, err := f.ts.CreateTask(f.ctx, t)
	if err != nil {
		f.t.Fatalf("create %q: %v", t.Name, err)
	}
	return out
}

// TestScheduledTaskRoundTrip: what CreateTask answers is what GetTask and
// ListTasks read back, with the defaults filled; UpdateTask keeps the
// identity fields; SetTaskState pauses, deletes and hides from the list.
func TestScheduledTaskRoundTrip(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newTaskFix(t, s)
			in := f.task()
			in.ScopeWhere = []string{"lobby", "feedback"}
			got := f.create(in)
			if !isUUID(got.TaskID) || got.State != TaskOn || got.MaxObjects != 100 || !got.UpdatedAt.Equal(f.t0) {
				t.Fatalf("defaults: %+v", got)
			}
			read, err := f.ts.GetTask(f.ctx, f.tn, strings.ToUpper(got.TaskID))
			if err != nil || !reflect.DeepEqual(read, got) {
				t.Fatalf("get:\n%+v %v\nwant\n%+v", read, err, got)
			}
			up := got
			up.Name, up.Level, up.CreatedBy, up.UpdatedAt = "nudge 2", TaskLevelInstance, "HUM-9", f.t0.Add(time.Minute)
			up.TriggerKind, up.Trigger = "weekly", TaskTriggerSpec{AtTime: "10:30", Weekdays: []int{1, 5}}
			after, err := f.ts.UpdateTask(f.ctx, up)
			if err != nil || after.Name != "nudge 2" || after.Level != TaskLevelWorkspace || after.CreatedBy != "HUM-1" ||
				!reflect.DeepEqual(after.Trigger.Weekdays, []int{1, 5}) {
				t.Fatalf("update: %+v %v", after, err)
			}
			if err := f.ts.SetTaskState(f.ctx, f.tn, got.TaskID, TaskPaused, "by_person", f.t0); err != nil {
				t.Fatal(err)
			}
			if p, _ := f.ts.GetTask(f.ctx, f.tn, got.TaskID); p.State != TaskPaused || p.PausedReason != "by_person" || !p.NextDueAt.IsZero() {
				t.Fatalf("paused: %+v", p)
			}
			if err := f.ts.SetTaskState(f.ctx, f.tn, got.TaskID, TaskDeleted, "", f.t0); err != nil {
				t.Fatal(err)
			}
			if ls, err := f.ts.ListTasks(f.ctx, f.tn); err != nil || len(ls) != 0 {
				t.Fatalf("a deleted task is listed: %v %v", ls, err)
			}
			if _, err := f.ts.UpdateTask(f.ctx, up); !errors.Is(err, ErrNotFound) {
				t.Fatalf("update of a deleted task: %v, want ErrNotFound", err)
			}
			if err := f.ts.SetTaskState(f.ctx, "other-ws", got.TaskID, TaskOn, "", f.t0); !errors.Is(err, ErrNotFound) {
				t.Fatalf("another workspace's state change: %v, want ErrNotFound", err)
			}
		})
	}
}

// TestScheduledTaskRefusals: every value outside rdb 0331's CHECKs, and
// every spec that does not fit its kind, is ErrBadTask before any write.
func TestScheduledTaskRefusals(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newTaskFix(t, s)
			with := func(fn func(x *ScheduledTask)) ScheduledTask { x := f.task(); fn(&x); return x }
			for why, x := range map[string]ScheduledTask{
				"trigger kind outside the seven": with(func(x *ScheduledTask) { x.TriggerKind = "hourly" }),
				"cron until S12b":                with(func(x *ScheduledTask) { x.TriggerKind, x.Trigger = "cron", TaskTriggerSpec{Cron: "*/15 * * * *"} }),
				"stray trigger field":            with(func(x *ScheduledTask) { x.Trigger.IntervalMin = 15 }),
				"daily 25:00":                    with(func(x *ScheduledTask) { x.Trigger.AtTime = "25:00" }),
				"weekly day 8":                   with(func(x *ScheduledTask) { x.TriggerKind, x.Trigger.Weekdays = "weekly", []int{8} }),
				"monthly day 29":                 with(func(x *ScheduledTask) { x.TriggerKind, x.Trigger.MonthDay = "monthly", 29 }),
				"interval over a week": with(func(x *ScheduledTask) {
					x.TriggerKind, x.Trigger = "every_n_minutes", TaskTriggerSpec{IntervalMin: TaskIntervalMax + 1}
				}),
				"unknown event":      with(func(x *ScheduledTask) { x.TriggerKind, x.Trigger = "event", TaskTriggerSpec{On: "file_new"} }),
				"once with no time":  with(func(x *ScheduledTask) { x.TriggerKind, x.Trigger = "once", TaskTriggerSpec{} }),
				"unknown action":     with(func(x *ScheduledTask) { x.ActionKind = "delete" }),
				"notify nobody":      with(func(x *ScheduledTask) { x.Action = TaskActionSpec{} }),
				"stray action field": with(func(x *ScheduledTask) { x.Action.Channel = "lobby" }),
				"priority 6":         with(func(x *ScheduledTask) { x.ActionKind, x.Action = "set_priority", TaskActionSpec{Priority: 6} }),
				"agent prompt over 4000": with(func(x *ScheduledTask) {
					x.ActionKind, x.Action = "agent", TaskActionSpec{Prompt: strings.Repeat("ä", TaskPromptMax+1)}
				}),
				"move to a bad channel":        with(func(x *ScheduledTask) { x.ActionKind, x.Action = "move", TaskActionSpec{Channel: "Bad Channel"} }),
				"object outside the four":      with(func(x *ScheduledTask) { x.ScopeObject = "file" }),
				"51 channels":                  with(func(x *ScheduledTask) { x.ScopeWhere = manyChannels(TaskWhereMax + 1) }),
				"query over 1024":              with(func(x *ScheduledTask) { x.ScopeQuery = strings.Repeat("q", 1025) }),
				"max objects 501":              with(func(x *ScheduledTask) { x.MaxObjects = TaskMaxObjects + 1 }),
				"unknown template":             with(func(x *ScheduledTask) { x.Template = "other" }),
				"name over 120":                with(func(x *ScheduledTask) { x.Name = strings.Repeat("n", TaskNameMax+1) }),
				"no owner":                     with(func(x *ScheduledTask) { x.OwnerID = "" }),
				"unknown zone":                 with(func(x *ScheduledTask) { x.TZ = "Mars/Olympus" }),
				"paused with no reason":        with(func(x *ScheduledTask) { x.State = TaskPaused }),
				"on with a reason":             with(func(x *ScheduledTask) { x.PausedReason = "cap" }),
				"workspace task at instance":   with(func(x *ScheduledTask) { x.Level = TaskLevelInstance }),
				"instance task in a workspace": with(func(x *ScheduledTask) { x.TenantID = "" }),
				"workspace lists instance ws":  with(func(x *ScheduledTask) { x.InstanceTenants = []string{"t1"} }),
			} {
				if _, err := f.ts.CreateTask(f.ctx, x); !errors.Is(err, ErrBadTask) {
					t.Errorf("%s: %v, want ErrBadTask", why, err)
				}
			}
			if ls, _ := f.ts.ListTasks(f.ctx, f.tn); len(ls) != 0 {
				t.Fatalf("a refused task was stored: %+v", ls)
			}
			if _, err := f.ts.CreateTask(f.ctx, with(func(x *ScheduledTask) { x.TenantID = "no-such-ws" })); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown workspace: %v, want ErrNotFound", err)
			}
			if err := f.ts.SetTaskState(f.ctx, f.tn, uuid4(), TaskPaused, "nap", f.t0); !errors.Is(err, ErrBadTask) {
				t.Fatalf("unknown pause reason: %v, want ErrBadTask", err)
			}
		})
	}
}

func manyChannels(n int) []string {
	out := make([]string, n)
	for i := range out {
		out[i] = "ch-" + strings.Repeat("x", i+1)
	}
	return out
}

// TestScheduledTaskClaimOnce is S1's done test: of two concurrent claimers
// one gets the due task, and a third claim at the same time gets nothing,
// because the claim moved next_due_at to next(task). CONTROL (S1's red):
// drop `next_due_at <= $1` from taskClaimSQL and the third claim takes the
// task again: it runs twice.
func TestScheduledTaskClaimOnce(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newTaskFix(t, s)
			due := f.create(f.task())
			later := f.task()
			later.NextDueAt = f.t0.Add(time.Hour)
			notYet := f.create(later)
			next := func(x ScheduledTask) time.Time { return x.NextDueAt.Add(24 * time.Hour) }
			var mu sync.Mutex
			claims := map[string]int{}
			claim := func() {
				got, err := f.ts.ClaimDueTasks(f.ctx, f.t0, next, TaskMaxObjects)
				if err != nil {
					t.Error(err)
					return
				}
				mu.Lock()
				defer mu.Unlock()
				for _, x := range got {
					claims[x.TaskID]++
					if x.TaskID == due.TaskID && !x.NextDueAt.Equal(f.t0) {
						t.Errorf("claimed row %v, want the row before the move (%v)", x.NextDueAt, f.t0)
					}
				}
			}
			var wg sync.WaitGroup
			for range 2 {
				wg.Add(1)
				go func() { defer wg.Done(); claim() }()
			}
			wg.Wait()
			claim()
			if claims[due.TaskID] != 1 || claims[notYet.TaskID] != 0 {
				t.Fatalf("claims %v: the due task %d times (want 1), the later one %d (want 0)",
					claims, claims[due.TaskID], claims[notYet.TaskID])
			}
			moved, _ := f.ts.GetTask(f.ctx, f.tn, due.TaskID)
			if !moved.NextDueAt.Equal(f.t0.Add(24 * time.Hour)) {
				t.Fatalf("next_due_at after the claim %v, want %v", moved.NextDueAt, f.t0.Add(24*time.Hour))
			}
			once := f.task()
			once.TriggerKind, once.Trigger = "once", TaskTriggerSpec{At: f.t0}
			ran := f.create(once)
			if _, err := f.ts.ClaimDueTasks(f.ctx, f.t0, func(ScheduledTask) time.Time { return time.Time{} }, TaskMaxObjects); err != nil {
				t.Fatal(err)
			}
			if r, _ := f.ts.GetTask(f.ctx, f.tn, ran.TaskID); !r.NextDueAt.IsZero() {
				t.Fatalf("a once task after its claim is due %v, want none", r.NextDueAt)
			}
		})
	}
}

// TestScheduledTaskInstance: an instance task (tenant "") is stored, listed
// and claimed apart from every workspace, and its event tasks reach the
// workspaces it lists.
func TestScheduledTaskInstance(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newTaskFix(t, s)
			other := newTenant(t, s)
			in := f.task()
			in.TenantID, in.Level, in.OwnerID, in.InstanceTenants = "", TaskLevelInstance, "HUB-0", []string{f.tn}
			in.TriggerKind, in.Trigger, in.NextDueAt = "event", TaskTriggerSpec{On: "issue_changed"}, time.Time{}
			inst := f.create(in)
			own := f.task()
			own.TriggerKind, own.Trigger, own.NextDueAt = "event", TaskTriggerSpec{On: "issue_new"}, time.Time{}
			mine := f.create(own)
			if _, err := f.ts.GetTask(f.ctx, f.tn, inst.TaskID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("a workspace reads the instance task: %v", err)
			}
			if got, err := f.ts.GetTask(f.ctx, "", inst.TaskID); err != nil || got.TenantID != "" || got.Level != TaskLevelInstance {
				t.Fatalf("instance get: %+v %v", got, err)
			}
			ids := func(ts []ScheduledTask) []string {
				var out []string
				for _, x := range ts {
					out = append(out, x.TaskID)
				}
				return out
			}
			if ls, _ := f.ts.ListTasks(f.ctx, ""); !strings.Contains(strings.Join(ids(ls), ","), inst.TaskID) {
				t.Fatalf("instance list %v lacks %s", ids(ls), inst.TaskID)
			}
			ev, err := f.ts.EventTasks(f.ctx, f.tn, "issue")
			if err != nil || !reflect.DeepEqual(ids(ev), []string{mine.TaskID, inst.TaskID}) && !reflect.DeepEqual(ids(ev), []string{inst.TaskID, mine.TaskID}) {
				t.Fatalf("event tasks of the listed workspace %v %v, want its own and the instance's", ids(ev), err)
			}
			if ev, _ := f.ts.EventTasks(f.ctx, other, "issue"); len(ev) != 0 {
				t.Fatalf("an unlisted workspace gets %v", ids(ev))
			}
			if ev, _ := f.ts.EventTasks(f.ctx, f.tn, "topic"); len(ev) != 0 {
				t.Fatalf("another object gets %v", ids(ev))
			}
		})
	}
}

// TestScheduledTaskRuns: StartRun is idempotent per cause (the second
// insert of one cause is a no-op), FinishRun closes the row, ListRuns reads
// newest first, and RunsSince counts by level, leaving out chain refusals.
func TestScheduledTaskRuns(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newTaskFix(t, s)
			task := f.create(f.task())
			cause := f.t0.Format(time.RFC3339)
			r := TaskRun{TenantID: f.tn, TaskID: task.TaskID, Cause: cause, Chain: []string{uuid4()}, StartedAt: f.t0}
			if ok, err := f.ts.StartRun(f.ctx, r); !ok || err != nil {
				t.Fatalf("first start: %v %v", ok, err)
			}
			if ok, err := f.ts.StartRun(f.ctx, r); ok || err != nil {
				t.Fatalf("second start of one cause: %v %v, want false, nil", ok, err)
			}
			id := TaskRunID(task.TaskID, cause)
			fin := TaskRun{TenantID: f.tn, RunID: id, Outcome: "partial", Matched: 3, Acted: 2, Tokens: 7,
				Failures: []TaskRunFailure{{Object: "SPL-1", Reason: "gone"}}, Error: strings.Repeat("e", 600),
				AgentID: "c-001", ResultMsgID: uuid4(), EndedAt: f.t0.Add(time.Second)}
			if err := f.ts.FinishRun(f.ctx, fin); err != nil {
				t.Fatal(err)
			}
			for i, c := range []struct{ out, err string }{{"ok", ""}, {"skipped", "chain_self A"}, {"skipped", "cap"}} {
				x := TaskRun{TenantID: f.tn, TaskID: task.TaskID, Cause: "c" + string(rune('a'+i)), Outcome: c.out,
					Error: c.err, StartedAt: f.t0.Add(time.Duration(i+1) * time.Minute)}
				if _, err := f.ts.StartRun(f.ctx, x); err != nil {
					t.Fatal(err)
				}
			}
			runs, err := f.ts.ListRuns(f.ctx, f.tn, task.TaskID, 10)
			if err != nil || len(runs) != 4 || runs[3].RunID != id {
				t.Fatalf("runs %+v %v", runs, err)
			}
			got := runs[3]
			if got.Outcome != "partial" || got.Matched != 3 || len([]rune(got.Error)) != 500 || got.AgentID != "c-001" ||
				!reflect.DeepEqual(got.Failures, fin.Failures) || !got.EndedAt.Equal(fin.EndedAt) || len(got.Chain) != 1 {
				t.Fatalf("finished run %+v", got)
			}
			if n, err := f.ts.RunsSince(f.ctx, f.tn, TaskLevelWorkspace, f.t0); err != nil || n != 3 {
				t.Fatalf("RunsSince %d %v, want 3 (the chain refusal not counted)", n, err)
			}
			if n, _ := f.ts.RunsSince(f.ctx, f.tn, TaskLevelWorkspace, f.t0.Add(2*time.Minute)); n != 1 {
				t.Fatalf("RunsSince from +2m %d, want 1", n)
			}
			inst := TaskRun{TenantID: f.tn, TaskID: task.TaskID, Cause: "i", Level: TaskLevelInstance, StartedAt: f.t0}
			if _, err := f.ts.StartRun(f.ctx, inst); err != nil {
				t.Fatal(err)
			}
			if n, _ := f.ts.RunsSince(f.ctx, f.tn, TaskLevelWorkspace, f.t0); n != 3 {
				t.Fatalf("an instance run counted for the workspace: %d", n)
			}
			if n, err := f.ts.RunsSince(f.ctx, "", TaskLevelInstance, f.t0); err != nil || n < 1 {
				t.Fatalf("instance RunsSince %d %v", n, err)
			}
			if _, err := f.ts.RunsSince(f.ctx, "", TaskLevelWorkspace, f.t0); !errors.Is(err, ErrNoTenant) {
				t.Fatalf("workspace count with no workspace: %v", err)
			}
			for why, bad := range map[string]TaskRun{
				"a chain of 4":  {TenantID: f.tn, TaskID: task.TaskID, Cause: "x", Chain: []string{uuid4(), uuid4(), uuid4(), uuid4()}},
				"no cause":      {TenantID: f.tn, TaskID: task.TaskID},
				"bad outcome":   {TenantID: f.tn, TaskID: task.TaskID, Cause: "y", Outcome: "done"},
				"task not uuid": {TenantID: f.tn, TaskID: "t", Cause: "z"},
			} {
				if _, err := f.ts.StartRun(f.ctx, bad); !errors.Is(err, ErrBadTask) {
					t.Errorf("%s: %v, want ErrBadTask", why, err)
				}
			}
			if err := f.ts.FinishRun(f.ctx, TaskRun{TenantID: f.tn, RunID: uuid4(), Outcome: "ok"}); !errors.Is(err, ErrNotFound) {
				t.Fatalf("finish of no run: %v", err)
			}
		})
	}
}

// TestHubSettings: a set value reads back, a second set replaces it, and a
// bad key or value is refused.
// TestScheduledTaskRunErrorCap (SPL-6659, R7 N1): StartRun cuts a run error
// to 500 characters, as FinishRun does, so Postgres's CHECK (length(error) <=
// 500) never answers 23514 and both stores keep the same 500 runes. The error
// is multibyte: a cut by bytes would keep 250 runes.
func TestScheduledTaskRunErrorCap(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			f := newTaskFix(t, s)
			task := f.create(f.task())
			long := strings.Repeat("ä", taskRunErrorMax+1)
			r := TaskRun{TenantID: f.tn, TaskID: task.TaskID, Cause: "cap", Outcome: "failed", Error: long, StartedAt: f.t0}
			if ok, err := f.ts.StartRun(f.ctx, r); !ok || err != nil {
				t.Fatalf("start with a %d-rune error: %v %v", taskRunErrorMax+1, ok, err)
			}
			runs, err := f.ts.ListRuns(f.ctx, f.tn, task.TaskID, 1)
			if err != nil || len(runs) != 1 {
				t.Fatalf("runs %+v %v", runs, err)
			}
			if got := runs[0].Error; got != long[:2*taskRunErrorMax] {
				t.Fatalf("stored error is %d runes, want the first %d", len([]rune(got)), taskRunErrorMax)
			}
		})
	}
}

func TestHubSettings(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx, ts := context.Background(), s.(ScheduledTaskStore)
			key := "tasks.test_" + strings.ReplaceAll(uuid4()[:8], "-", "")
			if _, ok, err := ts.HubSetting(ctx, key); ok || err != nil {
				t.Fatalf("unset key: %v %v", ok, err)
			}
			for _, v := range []string{`{"a": 1, "b": [true]}`, `50`} {
				if err := ts.SetHubSetting(ctx, key, json.RawMessage(v), "HUM-1", time.Now()); err != nil {
					t.Fatal(err)
				}
				got, ok, err := ts.HubSetting(ctx, key)
				var a, b any
				_ = json.Unmarshal(got, &a)
				_ = json.Unmarshal([]byte(v), &b)
				if !ok || err != nil || !reflect.DeepEqual(a, b) {
					t.Fatalf("read %s %v %v, want %s", got, ok, err, v)
				}
			}
			for _, c := range []struct{ key, v, by string }{{"Tasks", `1`, "x"}, {key, `{`, "x"}, {key, `1`, ""}} {
				if err := ts.SetHubSetting(ctx, c.key, json.RawMessage(c.v), c.by, time.Now()); !errors.Is(err, ErrBadHubSetting) {
					t.Errorf("%+v: %v, want ErrBadHubSetting", c, err)
				}
			}
		})
	}
}

// TestScheduledTaskChecks0331: each CHECK of rdb 0331 refuses its stray
// value written past the Go checks (SQLSTATE 23514). Postgres only.
func TestScheduledTaskChecks0331(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := newTenant(t, pg)
	exec := func(sql string, args ...any) error {
		return pg.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, sql, args...)
			return err
		})
	}
	// task inserts one task row with these level, name, object, trigger and action.
	task := func(tenant any, level, name, object, trigger, action string) error {
		return exec(`INSERT INTO scheduled_tasks (tenant_id, task_id, level, name, owner_id, scope_object,
				trigger_kind, trigger_spec, action_kind, action_spec, created_by, created_at, updated_at)
			VALUES ($1, gen_random_uuid(), $2, $3, 'HUM-1', $4, $5, '{}', $6, '{}', 'HUM-1', now(), now())`,
			tenant, level, name, object, trigger, action)
	}
	// run inserts one run row with this cause, chain length and outcome.
	run := func(cause string, chain int, outcome string) error {
		return exec(`INSERT INTO scheduled_task_runs (tenant_id, run_id, task_id, cause, chain, started_at, outcome)
			VALUES ($1, gen_random_uuid(), gen_random_uuid(), $2,
				ARRAY(SELECT gen_random_uuid() FROM generate_series(1, $3::int)), now(), $4)`, tn, cause, chain, outcome)
	}
	if err := task(tn, "workspace", "n", "issue", "daily", "notify"); err != nil {
		t.Fatalf("the valid task: %v", err)
	}
	if err := task(nil, "instance", "n", "issue", "daily", "notify"); err != nil {
		t.Fatalf("the valid instance task: %v", err)
	}
	if err := run("c", 3, "running"); err != nil {
		t.Fatalf("the valid run (a chain of 3): %v", err)
	}
	for why, err := range map[string]error{
		"trigger_kind outside the seven":  task(tn, "workspace", "n", "issue", "hourly", "notify"),
		"instance level with a tenant":    task(tn, "instance", "n", "issue", "daily", "notify"),
		"workspace level with no tenant":  task(nil, "workspace", "n", "issue", "daily", "notify"),
		"empty name":                      task(tn, "workspace", "", "issue", "daily", "notify"),
		"object outside the four":         task(tn, "workspace", "n", "file", "daily", "notify"),
		"action outside the six":          task(tn, "workspace", "n", "issue", "daily", "delete"),
		"a chain of 4":                    run("c", 4, "running"),
		"an empty cause":                  run("", 0, "running"),
		"an outcome outside the five":     run("c", 0, "done"),
		"a hub_settings key with a space": exec(`INSERT INTO hub_settings (key, value, set_by, set_at) VALUES ('Bad Key', '1', 'x', now())`),
	} {
		if sqlState(err) != "23514" {
			t.Errorf("%s: %v, want a CHECK violation (23514)", why, err)
		}
	}
}

// TestScheduledTaskRLS0331: a workspace's task is invisible to another
// workspace's scope even when the query forgets WHERE tenant_id, an
// instance row (tenant_id NULL) is invisible in every tenant scope and seen
// in the operator scope, and hub_settings shows no row outside it.
func TestScheduledTaskRLS0331(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	f := &taskFix{t: t, ctx: ctx, s: pg, ts: pg, tn: a, t0: time.Now().UTC().Truncate(time.Microsecond)}
	mine := f.create(f.task())
	in := f.task()
	in.TenantID, in.Level = "", TaskLevelInstance
	inst := f.create(in)
	if _, err := pg.StartRun(ctx, TaskRun{TenantID: a, TaskID: mine.TaskID, Cause: "x"}); err != nil {
		t.Fatal(err)
	}
	count := func(scope, sql string, args ...any) int {
		t.Helper()
		var n int
		var err error
		if scope == "" {
			err = pg.asOperatorQuery(ctx, sql, args, func(r pgx.Rows) error { return r.Scan(&n) })
		} else {
			err = pg.queryRowTenant(ctx, scope, sql, args, &n)
		}
		if err != nil {
			t.Fatal(err)
		}
		return n
	}
	const byID = `SELECT count(*) FROM scheduled_tasks WHERE task_id = ANY($1::uuid[])`
	ids := []string{mine.TaskID, inst.TaskID}
	if n := count(a, byID, ids); n != 1 {
		t.Fatalf("workspace A sees %d of its task and the instance's, want 1 (its own)", n)
	}
	if n := count(b, byID, ids); n != 0 {
		t.Fatalf("workspace B sees %d of them, want 0", n)
	}
	if n := count("", byID, ids); n != 2 {
		t.Fatalf("the operator scope sees %d, want 2", n)
	}
	if n := count(b, `SELECT count(*) FROM scheduled_task_runs WHERE task_id = $1`, mine.TaskID); n != 0 {
		t.Fatalf("workspace B sees %d of A's runs", n)
	}
	if n := count(a, `SELECT count(*) FROM hub_settings`); n != 0 {
		t.Fatalf("a tenant scope sees %d hub_settings rows", n)
	}
	if _, err := pg.GetTask(ctx, b, mine.TaskID); !errors.Is(err, ErrNotFound) {
		t.Fatalf("B reads A's task: %v", err)
	}
}

// TestScheduledRunsChannel0331: a new workspace has #scheduled-runs (the
// tenant trigger on Postgres, the default seeding on Memory), and on
// Postgres the migration applies a second time and gives a workspace that
// lacks the row its one #scheduled-runs (the backfill of existing ones).
// CONTROL: drop 'scheduled-runs' from the trigger's VALUES and the first
// Postgres check is red.
func TestScheduledRunsChannel0331(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tn := newTenant(t, s)
			if ok, err := s.ChannelKnown(context.Background(), tn, ChannelScheduledRuns); err != nil || !ok {
				t.Fatalf("a new workspace has no #scheduled-runs: %v %v", ok, err)
			}
			if !IsDefaultChannel(ChannelScheduledRuns) || !ChannelReserved(ChannelScheduledRuns) {
				t.Fatal("scheduled-runs is not a reserved default channel")
			}
		})
	}
	pg := rlsStore(t)
	ctx := context.Background()
	const file = "0331_scheduled_tasks.sql"
	// reapply forgets the ledger row, so Migrate runs the file again. The
	// first apply also undoes an earlier test's re-run of 0173, which
	// restores 0173's four-channel trigger body in the shared database.
	reapply := func() {
		t.Helper()
		if _, err := pg.pool.Exec(ctx, `DELETE FROM spool_schema_migrations WHERE filename = $1`, file); err != nil {
			t.Fatal(err)
		}
		applied, err := Migrate(ctx, pg.Pool(), sqlDir(t))
		if err != nil {
			t.Fatalf("apply of %s: %v", file, err)
		}
		again := false
		for _, a := range applied {
			again = again || (a.File == file && !a.Skipped)
		}
		if !again {
			t.Fatalf("%s was not re-applied: %+v", file, applied)
		}
	}
	reapply()
	tid := newTenant(t, pg)
	count := func(sql string, args ...any) int {
		t.Helper()
		var n int
		if err := pg.asOperatorQuery(ctx, sql, args, func(r pgx.Rows) error { return r.Scan(&n) }); err != nil {
			t.Fatal(err)
		}
		return n
	}
	const one = `SELECT count(*) FROM channels WHERE tenant_id = $1 AND channel_id = 'scheduled-runs' AND created_by = 'hub'`
	if n := count(one, tid); n != 1 {
		t.Fatalf("a new workspace has %d #scheduled-runs rows, want 1 (the tenant trigger)", n)
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM channels WHERE tenant_id = $1 AND channel_id = 'scheduled-runs'`, tid)
		return err
	}); err != nil {
		t.Fatal(err)
	}
	reapply()
	if n := count(one, tid); n != 1 {
		t.Fatalf("an existing workspace has %d #scheduled-runs rows after the apply, want 1", n)
	}
	if n := count(`SELECT count(*) FROM tenants t WHERE NOT EXISTS (SELECT 1 FROM channels c
		WHERE c.tenant_id = t.tenant_id AND c.channel_id = 'scheduled-runs')`); n != 0 {
		t.Fatalf("%d workspaces have no #scheduled-runs", n)
	}
}

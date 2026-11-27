// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/channelmove"
)

// Spec 187 8.1 on a real move (SPL-6659, R7 note N3 of row S1): the staying
// scheduled tasks of <SRC> lose the moved channel's id, from scope_where and
// from a move action's target; a task left with no channel is paused
// (channel_moved, rdb 0333). The P7 proofs then print 0 for the table: the
// 5.1 refs count, the 5.2 scan and the C13 diff.

// mvTasks are <SRC>'s tasks that name the moved channel, and one that does not.
type mvTasks struct {
	wide, only, mover, deleted, other ScheduledTask
}

func (f mvFix) seedTasks(t *testing.T) mvTasks {
	t.Helper()
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	mk := func(name string, where []string, kind string, a TaskActionSpec) ScheduledTask {
		obj := "topic"
		if kind == "move" {
			obj = "message"
		}
		out, err := f.pg.CreateTask(ctx, ScheduledTask{TenantID: f.src, Level: TaskLevelWorkspace, Name: name, OwnerID: f.both,
			ScopeObject: obj, ScopeWhere: where, TriggerKind: "daily", Trigger: TaskTriggerSpec{AtTime: "09:00"},
			ActionKind: kind, Action: a, NextDueAt: now.Add(time.Hour), CreatedBy: f.both, CreatedAt: now})
		if err != nil {
			t.Fatalf("create %s: %v", name, err)
		}
		return out
	}
	ts := mvTasks{
		wide:    mk("wide", []string{f.ch, f.stay}, "archive", TaskActionSpec{}),
		only:    mk("only", []string{f.ch}, "archive", TaskActionSpec{}),
		mover:   mk("mover", []string{f.stay}, "move", TaskActionSpec{Channel: f.ch}),
		deleted: mk("deleted", []string{f.ch}, "archive", TaskActionSpec{}),
		other:   mk("other", []string{f.stay}, "move", TaskActionSpec{Channel: f.stay}),
	}
	if err := f.pg.SetTaskState(ctx, f.src, ts.deleted.TaskID, TaskDeleted, "", now); err != nil {
		t.Fatal(err)
	}
	ts.deleted, _ = f.pg.GetTask(ctx, f.src, ts.deleted.TaskID)
	return ts
}

func (f mvFix) proofSet() channelmove.ProofSet {
	return channelmove.ProofSet{Src: f.src, Channel: f.ch, Name: f.ch}
}

// taskSnapshot is the C13 snapshot of <SRC>, read as the P7 step reads it.
func (f mvFix) taskSnapshot(t *testing.T) channelmove.Snapshot {
	t.Helper()
	var snap channelmove.Snapshot
	err := f.pg.asOperator(context.Background(), func(tx pgx.Tx) (err error) {
		snap, err = channelmove.TakeSnapshot(context.Background(), tx, f.proofSet())
		return err
	})
	if err != nil {
		t.Fatal(err)
	}
	return snap
}

// taskProofs are the P7 failures that name scheduled_tasks: the 5.1 refs
// count, the 5.2 scan and the C13 diff of before against now.
func (f mvFix) taskProofs(t *testing.T, before channelmove.Snapshot) []string {
	t.Helper()
	ctx, s := context.Background(), f.proofSet()
	var out []string
	err := f.pg.asOperator(ctx, func(tx pgx.Tx) error {
		set, err := channelmove.SetProofs(ctx, tx, s)
		if err != nil {
			return err
		}
		scan, err := channelmove.Scan(ctx, tx, s)
		if err != nil {
			return err
		}
		for _, p := range channelmove.Failed(append(set, scan...)) {
			if strings.HasPrefix(p.Name, "scheduled_tasks ") || strings.HasPrefix(p.Name, "scan scheduled_tasks.") {
				out = append(out, p.Name)
			}
		}
		return nil
	})
	if err != nil {
		t.Fatal(err)
	}
	for _, c := range channelmove.Diff(before, f.taskSnapshot(t), s, channelmove.Rules{}) {
		if c.Table == "scheduled_tasks" {
			out = append(out, "diff "+c.What+" "+strings.Join(c.Cols, ",")+": "+c.Why)
		}
	}
	return out
}

func TestApplyChannelMoveScheduledTasks(t *testing.T) {
	f := seedMove(t)
	ts := f.seedTasks(t)
	before := f.taskSnapshot(t)
	f.apply(t, f.req())
	get := func(x ScheduledTask) ScheduledTask {
		t.Helper()
		got, err := f.pg.GetTask(context.Background(), f.src, x.TaskID)
		if err != nil {
			t.Fatalf("%s: %v", x.Name, err)
		}
		return got
	}
	if got := get(ts.wide); !reflect.DeepEqual(got.ScopeWhere, []string{f.stay}) || got.State != TaskOn || got.NextDueAt.IsZero() {
		t.Errorf("wide: scope %v state %s due %v, want [%s] on, due kept", got.ScopeWhere, got.State, got.NextDueAt, f.stay)
	}
	for _, x := range []ScheduledTask{ts.only, ts.mover} {
		got := get(x)
		if got.State != TaskPaused || got.PausedReason != "channel_moved" || !got.NextDueAt.IsZero() {
			t.Errorf("%s: state %s reason %q due %v, want paused channel_moved, no due time", x.Name, got.State, got.PausedReason, got.NextDueAt)
		}
		if strings.Contains(strings.Join(got.ScopeWhere, ","), f.ch) || got.Action.Channel != "" {
			t.Errorf("%s still names the moved channel: scope %v, action %+v", x.Name, got.ScopeWhere, got.Action)
		}
	}
	if got := get(ts.mover); !reflect.DeepEqual(got.ScopeWhere, []string{f.stay}) {
		t.Errorf("mover: scope %v, want [%s] kept", got.ScopeWhere, f.stay)
	}
	if got := get(ts.deleted); len(got.ScopeWhere) != 0 || got.State != TaskDeleted || got.PausedReason != "" {
		t.Errorf("deleted: scope %v state %s reason %q, want the id gone and still deleted", got.ScopeWhere, got.State, got.PausedReason)
	}
	if got := get(ts.other); !reflect.DeepEqual(got, ts.other) {
		t.Errorf("a task that names no moved channel changed:\n got  %+v\n want %+v", got, ts.other)
	}
	if got := f.taskProofs(t, before); len(got) != 0 {
		t.Errorf("P7 proofs on scheduled_tasks must print 0, got %v", got)
	}
	f.checkTaskClaims(t, ts)
}

// checkTaskClaims: past every due time, the ticker's claim takes the task
// that kept a channel and neither paused one, so neither runs over every
// channel nor moves to a channel that left.
func (f mvFix) checkTaskClaims(t *testing.T, ts mvTasks) {
	t.Helper()
	due, err := f.pg.ClaimDueTasks(context.Background(), time.Now().Add(2*time.Hour),
		func(ScheduledTask) time.Time { return time.Time{} }, TaskMaxObjects)
	if err != nil {
		t.Fatal(err)
	}
	claimed := map[string]bool{}
	for _, x := range due {
		claimed[x.TaskID] = true
	}
	if !claimed[ts.wide.TaskID] || !claimed[ts.other.TaskID] {
		t.Errorf("the claim missed a task that still runs: wide %v, other %v", claimed[ts.wide.TaskID], claimed[ts.other.TaskID])
	}
	if claimed[ts.only.TaskID] || claimed[ts.mover.TaskID] {
		t.Errorf("a task the move left with no channel was claimed to run: only %v, mover %v", claimed[ts.only.TaskID], claimed[ts.mover.TaskID])
	}
}

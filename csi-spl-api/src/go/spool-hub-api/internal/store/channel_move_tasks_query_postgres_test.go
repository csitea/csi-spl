// SPDX-License-Identifier: AGPL-3.0-only

package store

import (
	"context"
	"testing"
	"time"
)

// Spec 187 8.1 on a real move, the query half (SPL-6692, owner HUM-10
// answer A, msg b65adfcd): a staying task's scope_query loses the in: terms
// that name the moved channel; a task the term limited to that channel is
// paused (channel_moved); the P7 proofs on scheduled_tasks print 0.
func TestApplyChannelMoveTaskScopeQuery(t *testing.T) {
	f := seedMove(t)
	ctx, now := context.Background(), time.Now().UTC().Truncate(time.Microsecond)
	mk := func(name, query string) ScheduledTask {
		out, err := f.pg.CreateTask(ctx, ScheduledTask{TenantID: f.src, Level: TaskLevelWorkspace, Name: name, OwnerID: f.both,
			ScopeObject: "topic", ScopeWhere: []string{f.stay}, ScopeQuery: query, TriggerKind: "daily",
			Trigger: TaskTriggerSpec{AtTime: "09:00"}, ActionKind: "archive", NextDueAt: now.Add(time.Hour), CreatedBy: f.both, CreatedAt: now})
		if err != nil {
			t.Fatalf("create %s: %v", name, err)
		}
		return out
	}
	limited := mk("limited", "in:#"+f.ch+" foo")
	negated := mk("negated", `-IN:#`+f.ch+` "keep this" bar`)
	either := mk("either", "in:#"+f.stay+" OR channel:"+f.ch)
	deleted := mk("deleted", "in:#"+f.ch)
	other := mk("other", "in:#"+f.ch+"-team foo")
	// R7 W4 (a-744): terms the parser reads that the first regex missed
	spaced := mk("spaced", `in:" #`+f.ch+` " foo`)
	paren := mk("paren", "in:#"+f.ch+"(foo)")
	phrase := mk("phrase", `"foo"in:#`+f.ch)
	if err := f.pg.SetTaskState(ctx, f.src, deleted.TaskID, TaskDeleted, "", now); err != nil {
		t.Fatal(err)
	}
	other, _ = f.pg.GetTask(ctx, f.src, other.TaskID)
	before := f.taskSnapshot(t)
	f.apply(t, f.req())
	want := []struct {
		task         ScheduledTask
		query, state string
		reason       string
	}{
		{limited, "foo", TaskPaused, "channel_moved"},
		{negated, `"keep this" bar`, TaskOn, ""},
		{either, "in:#" + f.stay, TaskOn, ""},
		{deleted, "", TaskDeleted, ""},
		{other, other.ScopeQuery, TaskOn, ""},
		{spaced, "foo", TaskPaused, "channel_moved"},
		{paren, "foo", TaskPaused, "channel_moved"},
		{phrase, `"foo"`, TaskPaused, "channel_moved"},
	}
	for _, w := range want {
		got, err := f.pg.GetTask(ctx, f.src, w.task.TaskID)
		if err != nil {
			t.Fatalf("%s: %v", w.task.Name, err)
		}
		if got.ScopeQuery != w.query || got.State != w.state || got.PausedReason != w.reason {
			t.Errorf("%s: query %q state %s reason %q, want %q %s %q", w.task.Name, got.ScopeQuery, got.State, got.PausedReason, w.query, w.state, w.reason)
		}
		if paused := w.state == TaskPaused; w.state != TaskDeleted && paused != got.NextDueAt.IsZero() {
			t.Errorf("%s: next due %v with state %s", w.task.Name, got.NextDueAt, got.State)
		}
	}
	if got, _ := f.pg.GetTask(ctx, f.src, other.TaskID); got.ScopeQuery != other.ScopeQuery || !got.UpdatedAt.Equal(other.UpdatedAt) {
		t.Errorf("a task that names no moved channel changed: %+v", got)
	}
	if p := f.taskProofs(t, before); len(p) != 0 {
		t.Errorf("P7 proofs on scheduled_tasks must print 0, got %v", p)
	}
}

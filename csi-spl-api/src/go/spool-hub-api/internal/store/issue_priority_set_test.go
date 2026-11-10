package store

import (
	"context"
	"testing"
	"time"
)

// Spec 150 section 3.4 item 4 v1.3 (rdb 0273, SPL-5223): an issue's own
// prio change stamps priority_set_at, a change it takes from its
// discussions does not; and a discussion's set row reads with its time.
// Memory always, Postgres with a DSN (hub-pg.tst.sh, PRE_PUSH_TIER=full).
// RED CONTROL: drop the CASE of UpdateIssue (or the memory stamp) and the
// own change reads absent.
func TestIssuePrioritySetAt(t *testing.T) {
	ctx := context.Background()
	t0 := time.Now().UTC().Truncate(time.Microsecond)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			is, os, ps := s.(Issues), s.(IssuePrioritySets), s.(TopicPriorityStore)
			tid := newTenant(t, s)
			task := uuid4()
			a, err := is.CreateIssue(ctx, Issue{Discussions: []string{task}, TenantID: tid, Title: "own", TaskID: uuid4(), CreatedBy: "HUM-1"}, t0)
			if err != nil {
				t.Fatal(err)
			}
			b, err := is.CreateIssue(ctx, Issue{Discussions: []string{task}, TenantID: tid, Title: "follows", TaskID: uuid4(), CreatedBy: "HUM-1"}, t0)
			if err != nil {
				t.Fatal(err)
			}
			one, two := 1, 2
			if _, err := is.UpdateIssue(ctx, tid, a.Number, IssuePatch{Priority: &one, PriorityOwn: true}, "HUM-1", t0.Add(time.Second)); err != nil {
				t.Fatal(err)
			}
			if _, err := is.UpdateIssue(ctx, tid, b.Number, IssuePatch{Priority: &two}, "HUM-1", t0.Add(2*time.Second)); err != nil {
				t.Fatal(err)
			}
			// the same value again changes nothing, so it does not stamp
			if _, err := is.UpdateIssue(ctx, tid, a.Number, IssuePatch{Priority: &one, PriorityOwn: true}, "HUM-1", t0.Add(3*time.Second)); err != nil {
				t.Fatal(err)
			}
			got, err := os.IssuePrioritySetAt(ctx, tid, nil)
			if err != nil || len(got) != 1 || !got[a.Number].Equal(t0.Add(time.Second)) {
				t.Fatalf("every issue: %v %v, want only %d at %v", got, err, a.Number, t0.Add(time.Second))
			}
			if got, err = os.IssuePrioritySetAt(ctx, tid, []int{b.Number}); err != nil || len(got) != 0 {
				t.Fatalf("the follower only: %v %v, want none", got, err)
			}
			if _, err := ps.SetTopicPriority(ctx, tid, task, 4, "HUM-2", t0); err != nil {
				t.Fatal(err)
			}
			rows, err := ps.SetTopicPriorityRows(ctx, tid, []string{task, uuid4()})
			if err != nil || len(rows) != 1 || rows[task].Priority != 4 || rows[task].SetBy != "HUM-2" || !rows[task].SetAt.Equal(t0) {
				t.Fatalf("topic rows: %+v %v", rows, err)
			}
		})
	}
}

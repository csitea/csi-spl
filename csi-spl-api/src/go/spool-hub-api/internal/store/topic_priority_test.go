package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 150 row B1 (rdb 0214, SPL-3052): a priority 1..5 per discussion.
// C301 and C302 run on Memory always and on Postgres with a DSN
// (hub-pg.tst.sh, PRE_PUSH_TIER=full); C304 and the CHECK half of C302 are
// Postgres only. C303 (the change stamp) is store/change_stamp_test.go.

// unsetTopicPriority is what a topic nobody set reads: 3, the owner's
// default (prd t1 0344254d, msg f5ed1396, spec 150 v1.1 D7, SPL-4367). A
// literal, not TopicPriorityDefault, so the tests hold the owner's value.
const unsetTopicPriority = 3

// TestTopicPrioritySetRead is C301: a set of 4 reads back 4; a topic nobody
// set, and an id that is no uuid, read 3; a second set replaces the first;
// another workspace reads its own default for the same task id.
// RED CONTROL: skip the write and the read stays 3; default 5 and the
// unset reads fail.
func TestTopicPrioritySetRead(t *testing.T) {
	ctx := context.Background()
	at := time.Now().UTC().Truncate(time.Microsecond)
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ps := s.(TopicPriorityStore)
			tid, other := newTenant(t, s), newTenant(t, s)
			task, unset := uuid4(), uuid4()
			got, err := ps.TopicPriorities(ctx, tid, []string{task})
			if err != nil || got[task] != unsetTopicPriority {
				t.Fatalf("before any set: %v %v, want %d", got, err, unsetTopicPriority)
			}
			row, err := ps.SetTopicPriority(ctx, tid, task, 4, "HUM-1", at)
			if err != nil {
				t.Fatal(err)
			}
			want := TopicPriority{TenantID: tid, TaskID: task, Priority: 4, SetBy: "HUM-1", SetAt: at}
			if row != want {
				t.Fatalf("set answered %+v, want %+v", row, want)
			}
			upper := strings.ToUpper(task)
			got, err = ps.TopicPriorities(ctx, tid, []string{task, unset, "not-a-uuid", upper})
			if err != nil {
				t.Fatal(err)
			}
			if got[task] != 4 || got[upper] != 4 || got[unset] != unsetTopicPriority || got["not-a-uuid"] != unsetTopicPriority || len(got) != 4 {
				t.Fatalf("read %v, want %s=4 (any case), the rest %d", got, task, unsetTopicPriority)
			}
			if row, err = ps.SetTopicPriority(ctx, tid, task, 1, "HUM-2", at.Add(time.Second)); err != nil || row.Priority != 1 || row.SetBy != "HUM-2" {
				t.Fatalf("second set: %+v %v", row, err)
			}
			if got, _ = ps.TopicPriorities(ctx, tid, []string{task}); got[task] != 1 {
				t.Fatalf("after the second set read %v, want 1", got)
			}
			if got, _ = ps.TopicPriorities(ctx, other, []string{task}); got[task] != unsetTopicPriority {
				t.Fatalf("another workspace read %v for the task, want %d", got, unsetTopicPriority)
			}
			if got, err = ps.TopicPriorities(ctx, tid, nil); err != nil || len(got) != 0 {
				t.Fatalf("no ids: %v %v", got, err)
			}
			if _, err := ps.SetTopicPriority(ctx, uid("t-"), task, 2, "HUM-1", at); !errors.Is(err, ErrNotFound) {
				t.Fatalf("set in no workspace: %v, want ErrNotFound", err)
			}
		})
	}
}

// TestTopicPriorityBounds is C302: 0 and 6 are refused before any write, 1
// and 5 are accepted; a task id that is no uuid is refused.
// RED CONTROL: widen the bounds in checkTopicPriority and 0 / 6 are written.
func TestTopicPriorityBounds(t *testing.T) {
	ctx := context.Background()
	at := time.Now().UTC()
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ps := s.(TopicPriorityStore)
			tid, task := newTenant(t, s), uuid4()
			for _, p := range []int{0, 6, -1} {
				if _, err := ps.SetTopicPriority(ctx, tid, task, p, "HUM-1", at); !errors.Is(err, ErrBadTopicPriority) {
					t.Errorf("priority %d: %v, want ErrBadTopicPriority", p, err)
				}
			}
			if got, _ := ps.TopicPriorities(ctx, tid, []string{task}); got[task] != unsetTopicPriority {
				t.Fatalf("a refused set wrote %v", got)
			}
			for _, p := range []int{1, 5} {
				if row, err := ps.SetTopicPriority(ctx, tid, task, p, "HUM-1", at); err != nil || row.Priority != p {
					t.Errorf("priority %d: %+v %v", p, row, err)
				}
			}
			if _, err := ps.SetTopicPriority(ctx, tid, "not-a-uuid", 2, "HUM-1", at); !errors.Is(err, ErrBadTopicTask) {
				t.Errorf("task not a uuid: %v, want ErrBadTopicTask", err)
			}
		})
	}
}

// TestTopicPriorityCheck is C302's database half: rdb 0214's CHECK refuses
// 0 and 6 written past the store (SQLSTATE 23514) and takes 1 and 5.
// RED CONTROL: widen the CHECK and 0 / 6 are written.
func TestTopicPriorityCheck(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tid := newTenant(t, pg)
	ins := `INSERT INTO topic_priorities (tenant_id, task_id, priority, set_by, set_at) VALUES ($1, $2, $3, 'HUM-1', now())`
	for _, p := range []int{0, 6} {
		if _, err := pg.execTenant(ctx, tid, ins, tid, uuid4(), p); pgCode(err) != "23514" {
			t.Errorf("priority %d past the store: %v, want CHECK (23514)", p, err)
		}
	}
	for _, p := range []int{1, 5} {
		if _, err := pg.execTenant(ctx, tid, ins, tid, uuid4(), p); err != nil {
			t.Errorf("priority %d: %v", p, err)
		}
	}
}

// priorityRows is how many of t1's topic_priorities rows a fresh
// transaction under scope reads: "tenant:<id>", "operator", "empty" or
// "none". lift drops FORCE row level security first (rolled back).
func priorityRows(t *testing.T, pg *Postgres, scope, t1 string, lift bool) int {
	t.Helper()
	ctx := context.Background()
	var n int
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) (err error) {
		if lift {
			if _, err = tx.Exec(ctx, `ALTER TABLE topic_priorities NO FORCE ROW LEVEL SECURITY`); err != nil {
				return err
			}
		}
		switch {
		case scope == "operator":
			_, err = tx.Exec(ctx, pgScopeOperator)
		case scope == "empty":
			_, err = tx.Exec(ctx, pgScopeTenant, "")
		case strings.HasPrefix(scope, "tenant:"):
			_, err = tx.Exec(ctx, pgScopeTenant, strings.TrimPrefix(scope, "tenant:"))
		}
		if err != nil {
			return err
		}
		if err = tx.QueryRow(ctx, `SELECT count(*) FROM topic_priorities WHERE tenant_id = $1`, t1).Scan(&n); err != nil {
			return err
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) {
		t.Fatalf("%s: %v", scope, err)
	}
	return n
}

// TestRLSTopicPriorities is C304 (as spec 099 7.4): workspace B's scope, an
// empty scope and no scope read none of A's rows; A's scope and the
// operator read them; B writing a row of A fails WITH CHECK, and B's
// update of A's rows touches none; B's store read of A's task is the
// default. CONTROL: with FORCE lifted (rolled back) the owner role reads A's
// rows under B's scope, so the zero counts are the policy's doing.
func TestRLSTopicPriorities(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	task := uuid4()
	if _, err := pg.SetTopicPriority(ctx, a, task, 2, "HUM-1", time.Now()); err != nil {
		t.Fatal(err)
	}
	for _, c := range []struct {
		scope string
		want  int
	}{{"tenant:" + b, 0}, {"empty", 0}, {"none", 0}, {"tenant:" + a, 1}, {"operator", 1}} {
		if got := priorityRows(t, pg, c.scope, a, false); got != c.want {
			t.Errorf("scope %s reads %d of A's rows, want %d", c.scope, got, c.want)
		}
	}
	_, err := pg.execTenant(ctx, b, `INSERT INTO topic_priorities (tenant_id, task_id, priority, set_by, set_at)
		VALUES ($1, $2, 1, 'HUM-9', now())`, a, uuid4())
	if pgCode(err) != "42501" {
		t.Errorf("A's row written under B's scope: %v (want WITH CHECK, 42501)", err)
	}
	tag, err := pg.execTenant(ctx, b, `UPDATE topic_priorities SET priority = 1 WHERE tenant_id = $1`, a)
	if err != nil || tag.RowsAffected() != 0 {
		t.Errorf("B's scope updated %d of A's rows: %v", tag.RowsAffected(), err)
	}
	if got, err := pg.TopicPriorities(ctx, b, []string{task}); err != nil || got[task] != unsetTopicPriority {
		t.Errorf("B read A's task as %v %v, want %d", got, err, unsetTopicPriority)
	}
	if got, err := pg.TopicPriorities(ctx, a, []string{task}); err != nil || got[task] != 2 {
		t.Errorf("A read its task as %v %v, want 2 (B's update reached it?)", got, err)
	}
	if got := priorityRows(t, pg, "tenant:"+b, a, true); got != 1 {
		t.Fatalf("CONTROL: without FORCE the owner read %d of A's rows under B's scope, want 1", got)
	}
}

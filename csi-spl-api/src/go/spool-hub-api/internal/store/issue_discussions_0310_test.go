package store

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// t1ForumTopic is t1's default discussion before rdb 0310: topic fcf09921.
const t1ForumTopic = "fcf09921-8f21-4518-a117-f8ddb41bfff5"

// SPL-6212 (rdb 0310; owner HUM-10, t1 438d96a1, msg 564f9723, "B"): t1's
// default discussion is its "Issue backlog" topic, as in every workspace, in
// SQL and in Go alike.
func TestIssueDiscussionDefaultT1Backlog(t *testing.T) {
	if got, want := IssueDiscussionDefault("t1"), IssueBacklogID("t1"); got != want {
		t.Fatalf("Go: t1's default %s, want its backlog topic %s", got, want)
	}
	pg := rlsStore(t)
	ctx := context.Background()
	var def string
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT issue_discussion_default('t1')::text`).Scan(&def)
	}); err != nil {
		t.Fatal(err)
	}
	if def != IssueBacklogID("t1") {
		t.Fatalf("SQL: t1's default %s, want its backlog topic %s", def, IssueBacklogID("t1"))
	}
}

// rdb 0310's move, run again on a fresh tenant in t1's place: an open issue
// linked to fcf09921 ends linked to the backlog topic instead (its other
// links and linked_at kept), a done or diss issue keeps fcf09921, and a
// second run changes nothing. The hub's probe then lists the tenant, so the
// hub posts its backlog topic.
func TestMigration0310MovesOpenT1Issues(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tn := newTenant(t, pg)
	move := move0310(t, tn)
	backlog, other := IssueBacklogID(tn), uuid4()
	then := time.Date(2026, 10, 13, 9, 0, 0, 0, time.UTC)
	mk := func(status string, ds ...string) int {
		t.Helper()
		i, err := pg.CreateIssue(ctx, Issue{TenantID: tn, Title: status, TaskID: uuid4(), CreatedBy: "HUM-1", Discussions: ds}, then)
		if err != nil {
			t.Fatal(err)
		}
		if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `UPDATE issues SET status = $3 WHERE tenant_id = $1 AND number = $2`, tn, i.Number, status)
			return err
		}); err != nil {
			t.Fatal(err)
		}
		return i.Number
	}
	wip, todoOther, evalBoth := mk(IssueWIP, t1ForumTopic), mk(IssueTodo, t1ForumTopic, other), mk(IssueEval, t1ForumTopic, backlog)
	done, diss := mk(IssueDone, t1ForumTopic), mk(IssueDiss, t1ForumTopic)
	for run := 1; run <= 2; run++ {
		if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, move)
			return err
		}); err != nil {
			t.Fatalf("run %d of the 0310 move: %v", run, err)
		}
		for _, c := range []struct {
			what string
			n    int
			want []string
		}{
			{"wip, fcf09921 only", wip, []string{backlog}},
			{"todo, fcf09921 + another", todoOther, []string{backlog, other}},
			{"eval, fcf09921 + backlog", evalBoth, []string{backlog}},
			{"done", done, []string{t1ForumTopic}},
			{"diss", diss, []string{t1ForumTopic}},
		} {
			if got := linkedTasks(t, pg, tn, c.n); !sameTasks(got, c.want...) {
				t.Errorf("run %d, %s: %v, want %v", run, c.what, got, c.want)
			}
		}
	}
	links, err := pg.IssueDiscussionLinks(ctx, tn, []int{wip})
	if err != nil || len(links[wip]) != 1 || !links[wip][0].LinkedAt.Equal(then) || links[wip][0].LinkedBy != "rdb-0310" {
		t.Fatalf("the moved link: %+v %v, want linked_at %s kept, linked_by rdb-0310", links[wip], err, then)
	}
	missing, err := pg.TenantsMissingIssueBacklog(ctx)
	if err != nil || !contains(missing, tn) {
		t.Fatalf("hub probe %v %v: want %s listed, its backlog topic not posted yet", missing, err, tn)
	}
}

// move0310 is rdb 0310's move, with tenant in place of 't1'.
func move0310(t testing.TB, tenant string) string {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(sqlDir(t), "0310_t1_issue_backlog_default.sql"))
	if err != nil {
		t.Fatal(err)
	}
	_, after, ok := strings.Cut(string(raw), "-- An open issue that already links the backlog topic")
	if !ok {
		t.Fatal("0310 has no move section")
	}
	if strings.Count(after, "'t1'") != 4 {
		t.Fatalf("0310's move names 't1' %d times, want 4", strings.Count(after, "'t1'"))
	}
	return "--" + strings.ReplaceAll(after, "'t1'", "'"+tenant+"'")
}

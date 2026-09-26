package store

import (
	"context"
	"errors"
	"strings"
	"sync"
	"testing"
	"time"
)

// testEpic makes the tenant's epic label and one epic; returns its number.
func testEpic(t *testing.T, is Issues, tenant string, now time.Time) int {
	t.Helper()
	if _, err := is.CreateIssueLabel(context.Background(), IssueLabel{TenantID: tenant, LabelID: IssueEpicLabel, Name: IssueEpicLabel}, now); err != nil && !errors.Is(err, ErrConflict) {
		t.Fatal(err)
	}
	e, err := is.CreateIssue(context.Background(), Issue{TenantID: tenant, Title: "an epic", Labels: []string{IssueEpicLabel}, TaskID: uuid4(), CreatedBy: "HUM-1"}, now)
	if err != nil {
		t.Fatal(err)
	}
	return e.Number
}

// rdb 0047 (specs/039, CLE-34993) on memory and, with SPOOL_TEST_PG_DSN,
// Postgres: numbering per tenant, the field checks, labels and parents that
// must exist, the status clocks, and one tenant never reading another's.
func TestIssues(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			is := s.(Issues)
			a, b := uid("ia-"), uid("ib-")
			for _, tn := range []string{a, b} {
				if err := s.CreateTenant(ctx, Tenant{ID: tn, RootPubKey: pubkey()}); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := is.CreateIssue(ctx, Issue{TenantID: uid("nope-"), Title: "x", TaskID: uuid4(), CreatedBy: "HUM-1"}, now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown tenant: %v", err)
			}
			for _, bad := range []Issue{
				{Title: " "}, {Title: strings.Repeat("t", 256)}, {Title: "x", Status: "doing"}, {Title: "x", Priority: 5},
				{Title: "x", Level: 6}, {Title: "x", Assignee: "bob"}, {Title: "x", Labels: []string{"Bad Label"}},
				{Title: "x", Description: strings.Repeat("d", IssueDescriptionMax+1)},
			} {
				bad.TenantID, bad.TaskID, bad.CreatedBy = a, uuid4(), "HUM-1"
				if _, err := is.CreateIssue(ctx, bad, now); !errors.Is(err, ErrInvalidIssue) {
					t.Fatalf("bad issue %+v: %v", bad, err)
				}
			}
			ea := testEpic(t, is, a, now)
			if _, err := is.CreateIssue(ctx, Issue{TenantID: a, Title: "x", TaskID: uuid4(), CreatedBy: "HUM-1", Parent: ea, Labels: []string{"bug"}}, now); !errors.Is(err, ErrUnknownLabel) {
				t.Fatalf("unknown label: %v", err)
			}
			if _, err := is.CreateIssue(ctx, Issue{TenantID: a, Title: "x", TaskID: uuid4(), CreatedBy: "HUM-1", Parent: 99}, now); !errors.Is(err, ErrUnknownParent) {
				t.Fatalf("unknown parent: %v", err)
			}
			bug, err := is.CreateIssueLabel(ctx, IssueLabel{TenantID: a, Name: " Bug ", Color: "#FF0000", CreatedBy: "HUM-1"}, now)
			if err != nil || bug.LabelID != "bug" || bug.Color != "#ff0000" || bug.Name != "Bug" {
				t.Fatalf("label: %+v %v", bug, err)
			}
			if _, err := is.CreateIssueLabel(ctx, IssueLabel{TenantID: a, Name: "bug"}, now); !errors.Is(err, ErrConflict) {
				t.Fatalf("dup label: %v", err)
			}
			if _, err := is.CreateIssueLabel(ctx, IssueLabel{TenantID: a, Name: "x", Color: "red"}, now); !errors.Is(err, ErrInvalidIssue) {
				t.Fatalf("bad colour: %v", err)
			}
			dl := now.Add(48 * time.Hour)
			task := uuid4()
			one, err := is.CreateIssue(ctx, Issue{TenantID: a, Title: "  First  ", Description: "## md", Priority: 1, Level: 3,
				Assignee: "CLE-01", Labels: []string{"bug", "bug"}, Deadline: &dl, TaskID: task, CreatedBy: "HUM-1", Parent: ea}, now)
			if err != nil {
				t.Fatal(err)
			}
			if one.Number != ea+1 || one.Key() != IssueKey("SPL", ea+1) || one.Title != "First" || one.Status != IssueBacklog || one.Priority != 1 ||
				one.Level != 3 || one.Assignee != "CLE-01" || len(one.Labels) != 1 || one.Deadline == nil || !one.Deadline.Equal(dl) ||
				one.TaskID != task || one.UpdatedBy != "HUM-1" || !one.CreatedAt.Equal(now) || one.CompletedAt != nil || one.Parent != ea || one.IsEpic() {
				t.Fatalf("created: %+v", one)
			}
			if _, err := is.CreateIssue(ctx, Issue{TenantID: a, Title: "dup task", TaskID: task, CreatedBy: "HUM-1", Parent: ea}, now); !errors.Is(err, ErrConflict) {
				t.Fatalf("dup task_id: %v", err)
			}
			two, err := is.CreateIssue(ctx, Issue{TenantID: a, Title: "Second", Status: IssueDone, Parent: ea, TaskID: uuid4(), CreatedBy: "CLE-01"}, now)
			if err != nil || two.Number != ea+2 || two.Parent != ea || two.CompletedAt == nil {
				t.Fatalf("second: %+v %v", two, err)
			}
			// B numbers from 1 and sees none of A's.
			eb := testEpic(t, is, b, now)
			other, err := is.CreateIssue(ctx, Issue{TenantID: b, Title: "B's", TaskID: uuid4(), CreatedBy: "HUM-2", Parent: eb}, now)
			if err != nil || eb != 1 || other.Number != 2 {
				t.Fatalf("tenant b: %+v %v", other, err)
			}
			if l, _ := is.ListIssues(ctx, b); len(l) != 2 || l[0].Title != "B's" {
				t.Fatalf("b list: %+v", l)
			}
			if _, err := is.GetIssue(ctx, b, two.Number); !errors.Is(err, ErrNotFound) {
				t.Fatalf("b reads a's: %v", err)
			}
			if _, err := is.UpdateIssue(ctx, b, 2, IssuePatch{Title: ptr("stolen")}, "HUM-2", now); err != nil {
				t.Fatal(err) // B's own issue 2
			}
			if got, _ := is.GetIssue(ctx, a, 2); got.Title != "First" {
				t.Fatalf("b's update reached a: %+v", got)
			}
			if bl, _ := is.ListIssueLabels(ctx, b); len(bl) != 1 || bl[0].LabelID != IssueEpicLabel {
				t.Fatalf("b labels: %+v", bl)
			}
			// Update: status clocks, clears.
			later := now.Add(time.Minute)
			up, err := is.UpdateIssue(ctx, a, one.Number, IssuePatch{Status: ptr(IssueCanceled), Priority: ptrInt(0), Assignee: ptr(""),
				Labels: &[]string{}, DeadlineSet: true}, "HUM-3", later)
			if err != nil || up.Status != IssueCanceled || up.CanceledAt == nil || !up.CanceledAt.Equal(later) || up.Priority != 0 ||
				up.Assignee != "" || len(up.Labels) != 0 || up.Deadline != nil || up.UpdatedBy != "HUM-3" || !up.UpdatedAt.Equal(later) ||
				up.Title != "First" || up.Level != 3 || up.Parent != ea {
				t.Fatalf("update: %+v %v", up, err)
			}
			if up, _ = is.UpdateIssue(ctx, a, one.Number, IssuePatch{Status: ptr(IssueTodo)}, "HUM-3", later); up.CanceledAt != nil || up.CompletedAt != nil {
				t.Fatalf("status back: %+v", up)
			}
			if _, err := is.UpdateIssue(ctx, a, one.Number, IssuePatch{Level: ptrInt(9)}, "HUM-3", later); !errors.Is(err, ErrInvalidIssue) {
				t.Fatalf("bad level: %v", err)
			}
			if _, err := is.UpdateIssue(ctx, a, 999, IssuePatch{Title: ptr("x")}, "HUM-3", later); !errors.Is(err, ErrNotFound) {
				t.Fatalf("missing: %v", err)
			}
			list, err := is.ListIssues(ctx, a)
			if err != nil || len(list) != 3 || list[0].Number != two.Number || list[2].Number != ea || list[0].Prefix != "SPL" {
				t.Fatalf("list: %+v %v", list, err)
			}
			if p, err := is.IssuePrefix(ctx, a); err != nil || p != "SPL" {
				t.Fatalf("prefix: %q %v", p, err)
			}
		})
	}
}

// SPL-18: an epic has no parent; every other issue has exactly one parent,
// and it is an epic; an epic with issues keeps its label.
func TestIssueEpicRule(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			is := s.(Issues)
			tn := uid("ie-")
			if err := s.CreateTenant(ctx, Tenant{ID: tn, RootPubKey: pubkey()}); err != nil {
				t.Fatal(err)
			}
			e1 := testEpic(t, is, tn, now)
			e2 := testEpic(t, is, tn, now)
			mk := func(parent int, labels ...string) (Issue, error) {
				return is.CreateIssue(ctx, Issue{TenantID: tn, Title: "i", Parent: parent, Labels: labels, TaskID: uuid4(), CreatedBy: "HUM-1"}, now)
			}
			if _, err := mk(0); !errors.Is(err, ErrEpicRequired) {
				t.Fatalf("no epic: %v", err)
			}
			if _, err := mk(e1, IssueEpicLabel); !errors.Is(err, ErrBadEpic) {
				t.Fatalf("epic with a parent: %v", err)
			}
			child, err := mk(e1)
			if err != nil {
				t.Fatal(err)
			}
			if _, err := mk(child.Number); !errors.Is(err, ErrBadEpic) {
				t.Fatalf("parent is not an epic: %v", err)
			}
			// Move to the other epic: fine. Clear the epic: refused.
			if got, err := is.UpdateIssue(ctx, tn, child.Number, IssuePatch{Parent: ptrInt(e2)}, "HUM-1", now); err != nil || got.Parent != e2 {
				t.Fatalf("move: %+v %v", got, err)
			}
			if _, err := is.UpdateIssue(ctx, tn, child.Number, IssuePatch{Parent: ptrInt(0)}, "HUM-1", now); !errors.Is(err, ErrEpicRequired) {
				t.Fatalf("clear epic: %v", err)
			}
			// An epic with issues keeps its label; an empty one may drop it
			// only by getting an epic itself.
			if _, err := is.UpdateIssue(ctx, tn, e2, IssuePatch{Labels: &[]string{}, Parent: ptrInt(e1)}, "HUM-1", now); !errors.Is(err, ErrEpicHasIssues) {
				t.Fatalf("epic with issues lost its label: %v", err)
			}
			if _, err := is.UpdateIssue(ctx, tn, e1, IssuePatch{Labels: &[]string{}}, "HUM-1", now); !errors.Is(err, ErrEpicRequired) {
				t.Fatalf("epic -> issue without an epic: %v", err)
			}
			if got, err := is.UpdateIssue(ctx, tn, e1, IssuePatch{Labels: &[]string{}, Parent: ptrInt(e2)}, "HUM-1", now); err != nil || got.IsEpic() || got.Parent != e2 {
				t.Fatalf("empty epic -> issue: %+v %v", got, err)
			}
			// CONTROL: an issue becomes an epic only without a parent.
			if _, err := is.UpdateIssue(ctx, tn, child.Number, IssuePatch{Labels: &[]string{IssueEpicLabel}}, "HUM-1", now); !errors.Is(err, ErrBadEpic) {
				t.Fatalf("issue -> epic keeping its parent: %v", err)
			}
			if got, err := is.UpdateIssue(ctx, tn, child.Number, IssuePatch{Labels: &[]string{IssueEpicLabel}, Parent: ptrInt(0)}, "HUM-1", now); err != nil || !got.IsEpic() {
				t.Fatalf("issue -> epic: %+v %v", got, err)
			}
		})
	}
}

// Concurrent creates in one tenant never share a number.
func TestIssueNumbersConcurrent(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			tn := uid("ic-")
			if err := s.CreateTenant(ctx, Tenant{ID: tn, RootPubKey: pubkey()}); err != nil {
				t.Fatal(err)
			}
			is := s.(Issues)
			ep := testEpic(t, is, tn, time.Now())
			var wg sync.WaitGroup
			var mu sync.Mutex
			seen := map[int]bool{}
			for k := 0; k < 8; k++ {
				wg.Add(1)
				go func() {
					defer wg.Done()
					i, err := is.CreateIssue(ctx, Issue{TenantID: tn, Title: "c", TaskID: uuid4(), CreatedBy: "HUM-1", Parent: ep}, time.Now())
					if err != nil {
						t.Error(err)
						return
					}
					mu.Lock()
					defer mu.Unlock()
					if seen[i.Number] {
						t.Errorf("number %d handed out twice", i.Number)
					}
					seen[i.Number] = true
				}()
			}
			wg.Wait()
			if len(seen) != 8 {
				t.Fatalf("numbers: %v", seen)
			}
		})
	}
}

func TestParseIssueRef(t *testing.T) {
	for in, want := range map[string]int{"SPL-12": 12, "spl-3": 3, "7": 7, " 9 ": 9} {
		if n, ok := ParseIssueRef(in); !ok || n != want {
			t.Errorf("%q: %d %v", in, n, ok)
		}
	}
	for _, in := range []string{"", "0", "-1", "SPL-", "SPL-01", "a-b-c", "S PL-1", "SPL-1x"} {
		if n, ok := ParseIssueRef(in); ok {
			t.Errorf("%q accepted as %d", in, n)
		}
	}
	if LabelSlug("  Needs Design!! ") != "needs-design" {
		t.Error(LabelSlug("  Needs Design!! "))
	}
}

func ptr(s string) *string { return &s }
func ptrInt(n int) *int    { return &n }

// NoIssues hides an issue's discussion topic from a topic list (specs/039):
// the probe must bite on both drivers, and leave every other topic.
func TestIssueTopicsHidden(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tn := uid("ih-")
			if err := s.CreateTenant(ctx, Tenant{ID: tn, RootPubKey: pubkey()}); err != nil {
				t.Fatal(err)
			}
			issueTask, plainTask := uuid4(), uuid4()
			if _, err := s.(Issues).CreateIssue(ctx, Issue{TenantID: tn, Title: "x", TaskID: issueTask, CreatedBy: "HUM-1", Parent: testEpic(t, s.(Issues), tn, now)}, now); err != nil {
				t.Fatal(err)
			}
			for _, task := range []string{issueTask, plainTask} {
				m := msgFor(tn, task, "box-a", now, now, "env-"+task)
				m.Channel = ChannelTasks
				if _, err := s.InsertMessage(ctx, m); err != nil {
					t.Fatal(err)
				}
			}
			q := TopicQuery{Channel: ChannelTasks, Now: now, Limit: 10}
			if rows, err := s.ViewTopics(ctx, tn, q); err != nil || len(rows) != 2 {
				t.Fatalf("control: %v %+v", err, rows)
			}
			q.NoIssues = true
			if rows, err := s.ViewTopics(ctx, tn, q); err != nil || len(rows) != 1 || rows[0].TaskID != plainTask {
				t.Fatalf("NoIssues: %v %+v", err, rows)
			}
		})
	}
}

package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// rdb 0181 on memory and, with SPOOL_TEST_PG_DSN, Postgres: an issue's
// history is created, each field change with old -> new and its actor, each
// comment of its topic, archive / unarchive and the level cascade, oldest
// first; another tenant never reads it, a deleted issue has none.
func TestIssueHistory(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			t0 := time.Now().UTC().Truncate(time.Second).Add(-time.Hour)
			at := func(m int) time.Time { return t0.Add(time.Duration(m) * time.Minute) }
			is, hs := s.(Issues), s.(IssueHistories)
			a, b := uid("iha-"), uid("ihb-")
			for _, tn := range []string{a, b} {
				if err := s.CreateTenant(ctx, Tenant{ID: tn, RootPubKey: pubkey()}); err != nil {
					t.Fatal(err)
				}
			}
			task := uuid4()
			one, err := is.CreateIssue(ctx, Issue{TenantID: a, Title: "first", TaskID: task, CreatedBy: "HUM-1"}, at(0))
			if err != nil {
				t.Fatal(err)
			}
			kid, err := is.CreateIssue(ctx, Issue{TenantID: a, Title: "kid", TaskID: uuid4(), CreatedBy: "HUM-1", Parent: one.Number}, at(0))
			if err != nil || kid.Level != 3 {
				t.Fatalf("subtask: %+v %v", kid, err)
			}
			st, prio, who, desc := IssueBlocked, 2, "CLE-01", "## new"
			if _, err := is.UpdateIssue(ctx, a, one.Number, IssuePatch{Status: &st, Priority: &prio, Assignee: &who, Description: &desc}, "HUM-2", at(1)); err != nil {
				t.Fatal(err)
			}
			c := msgFor(a, task, "box-wui", at(2), at(2), "c1")
			c.FromID, c.Body = "HUM-3", strings.Repeat("x", 300)
			if _, err := s.InsertMessage(ctx, c); err != nil {
				t.Fatal(err)
			}
			kind := IssueKindFeature // an epic-kind row: its subtask becomes an issue (level 2)
			if _, err := is.UpdateIssue(ctx, a, one.Number, IssuePatch{Kind: &kind}, "HUM-2", at(3)); err != nil {
				t.Fatal(err)
			}
			if _, _, err := is.ArchiveIssue(ctx, a, one.Number, "HUM-4", at(4), true); err != nil {
				t.Fatal(err)
			}
			if _, _, err := is.UnarchiveIssue(ctx, a, one.Number, "HUM-5", at(5), true); err != nil {
				t.Fatal(err)
			}

			got, err := hs.IssueHistory(ctx, a, one.Number)
			if err != nil {
				t.Fatal(err)
			}
			var lines []string
			for _, e := range got {
				l := e.At.Sub(t0).String() + " " + e.Actor + " " + e.Event
				if e.Field != "" {
					l += " " + e.Field + " " + deref(e.Old) + "->" + deref(e.New)
				}
				if e.Event == IssueEventCommented {
					if e.MsgID != c.MsgID || len(deref(e.New)) != issueCommentExcerpt {
						t.Fatalf("comment: %+v", e)
					}
				}
				lines = append(lines, l)
			}
			want := []string{
				"0s HUM-1 created",
				"1m0s HUM-2 changed description ->",
				"1m0s HUM-2 changed status " + IssueBacklog + "->" + IssueBlocked,
				"1m0s HUM-2 changed priority 5->2",
				"1m0s HUM-2 changed assignee ->CLE-01",
				"2m0s HUM-3 commented",
				"3m0s HUM-2 changed level 2->1",
				"3m0s HUM-2 changed kind issue->feature",
				"4m0s HUM-4 archived",
				"5m0s HUM-5 unarchived",
			}
			if strings.Join(lines, "\n") != strings.Join(want, "\n") {
				t.Fatalf("history:\n%s\nwant:\n%s", strings.Join(lines, "\n"), strings.Join(want, "\n"))
			}
			// The cascade names who moved the subtask.
			kh, err := hs.IssueHistory(ctx, a, kid.Number)
			if err != nil || len(kh) < 2 || kh[1].Actor != "HUM-2" || kh[1].Field != "level" || deref(kh[1].New) != "2" {
				t.Fatalf("subtask history: %+v %v", kh, err)
			}
			if _, err := hs.IssueHistory(ctx, b, one.Number); !errors.Is(err, ErrNotFound) {
				t.Fatalf("other tenant: %v", err)
			}
			if _, _, err := is.DeleteIssueCascade(ctx, a, one.Number, "HUM-6", at(6)); err != nil {
				t.Fatal(err)
			}
			if _, err := hs.IssueHistory(ctx, a, one.Number); !errors.Is(err, ErrNotFound) {
				t.Fatalf("deleted: %v", err)
			}
		})
	}
}

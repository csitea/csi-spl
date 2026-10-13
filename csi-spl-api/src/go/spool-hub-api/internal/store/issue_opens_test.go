package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// SPL-1559 (rdb 0184): a member's opened issues are theirs only, a second
// open keeps the first, and an unknown issue is ErrNotFound. Memory and, with
// SPOOL_TEST_PG_DSN, Postgres.
func TestIssueOpensPerMember(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			io, ok := s.(IssueOpens)
			if !ok {
				t.Fatalf("%s store has no IssueOpens", name)
			}
			is := s.(Issues)
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			tid := newTenant(t, s)
			one, err := is.CreateIssue(ctx, Issue{Discussions: []string{uuid4()}, TenantID: tid, Title: "one", TaskID: uuid4(), CreatedBy: "HUM-1", Assignee: "HUM-2"}, now)
			if err != nil {
				t.Fatal(err)
			}
			two, err := is.CreateIssue(ctx, Issue{Discussions: []string{uuid4()}, TenantID: tid, Title: "two", TaskID: uuid4(), CreatedBy: "HUM-1", Assignee: "HUM-2"}, now)
			if err != nil {
				t.Fatal(err)
			}
			if got, err := io.IssuesOpenedBy(ctx, tid, "HUM-2"); err != nil || len(got) != 0 {
				t.Fatalf("before any open: %v %v, want none", got, err)
			}
			for range 2 {
				if err := io.MarkIssueOpened(ctx, tid, "HUM-2", one.Number, now); err != nil {
					t.Fatal(err)
				}
			}
			got, err := io.IssuesOpenedBy(ctx, tid, "HUM-2")
			if err != nil || len(got) != 1 || !got[one.Number] || got[two.Number] {
				t.Fatalf("HUM-2 opened = %v %v, want only %d", got, err, one.Number)
			}
			if other, err := io.IssuesOpenedBy(ctx, tid, "HUM-3"); err != nil || len(other) != 0 {
				t.Fatalf("HUM-3 opened = %v %v, want none", other, err)
			}
			if err := io.MarkIssueOpened(ctx, tid, "HUM-2", 999, now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("unknown issue: %v, want ErrNotFound", err)
			}
			if err := io.MarkIssueOpened(ctx, newTenant(t, s), "HUM-2", one.Number, now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("another tenant's number: %v, want ErrNotFound", err)
			}
		})
	}
}

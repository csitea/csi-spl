package store

import (
	"context"
	"testing"
	"time"
)

// SPL-4788: IssueLastNumber is the highest number the tenant handed out
// (issue_counters.last_number), 0 before the first issue; a soft delete keeps
// it, and another tenant's count never shows.
func TestIssueLastNumber(t *testing.T) {
	type counter interface {
		IssueLastNumber(ctx context.Context, tenant string) (int, error)
	}
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			now := time.Now().UTC().Truncate(time.Microsecond)
			is, cs := s.(Issues), s.(counter)
			a, b := uid("ln-"), uid("ln-")
			for _, tn := range []string{a, b} {
				if err := s.CreateTenant(ctx, Tenant{ID: tn, RootPubKey: pubkey()}); err != nil {
					t.Fatal(err)
				}
			}
			if n, err := cs.IssueLastNumber(ctx, a); err != nil || n != 0 {
				t.Fatalf("no issue yet: %d %v", n, err)
			}
			for range 3 {
				if _, err := is.CreateIssue(ctx, Issue{Discussions: []string{uuid4()}, TenantID: a, Title: "x", TaskID: uuid4(), CreatedBy: "HUM-1"}, now); err != nil {
					t.Fatal(err)
				}
			}
			if _, err := is.DeleteIssue(ctx, a, 3, "HUM-1", now); err != nil {
				t.Fatal(err)
			}
			if n, err := cs.IssueLastNumber(ctx, a); err != nil || n != 3 {
				t.Fatalf("three issues, the top one deleted: %d %v", n, err)
			}
			if n, err := cs.IssueLastNumber(ctx, b); err != nil || n != 0 {
				t.Fatalf("another tenant: %d %v", n, err)
			}
		})
	}
}

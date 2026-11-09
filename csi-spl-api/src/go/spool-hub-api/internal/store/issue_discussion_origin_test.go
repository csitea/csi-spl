package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// SPL-5126: a foreign link keeps its origin workspace, reads back with it, is
// no topic of the issue's own workspace, and the member unlink cannot take it.
func TestIssueOriginDiscussionLink(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			is, d := s.(Issues), s.(IssueDiscussions)
			now := time.Now().UTC().Truncate(time.Microsecond)
			tn, origin := newTenant(t, s), newTenant(t, s)
			own, foreign := uuid4(), uuid4()
			i, err := is.CreateIssue(ctx, Issue{TenantID: tn, Title: "x", TaskID: uuid4(), CreatedBy: "HUM-1", Discussions: []string{own}}, now)
			if err != nil {
				t.Fatal(err)
			}
			added, err := d.LinkIssueOriginDiscussion(ctx, tn, i.Number, origin, foreign, "operator", now)
			if err != nil || !added {
				t.Fatalf("link: %v %v", added, err)
			}
			if added, err = d.LinkIssueOriginDiscussion(ctx, tn, i.Number, origin, foreign, "operator", now); err != nil || added {
				t.Fatalf("second link: %v %v", added, err)
			}
			links, err := d.IssueDiscussionLinks(ctx, tn, []int{i.Number})
			if err != nil {
				t.Fatal(err)
			}
			found := map[string]string{}
			for _, l := range links[i.Number] {
				found[l.TaskID] = l.OriginTenant
			}
			if v, ok := found[foreign]; !ok || v != origin || found[own] != "" {
				t.Fatalf("links: %v", found)
			}
			nums, err := is.IssueNumbersByDiscussion(ctx, tn, foreign)
			if err != nil || len(nums) != 0 {
				t.Fatalf("a foreign link counted as a topic of the workspace: %v %v", nums, err)
			}
			if err := d.UnlinkIssueDiscussion(ctx, tn, i.Number, foreign); !errors.Is(err, ErrNotFound) {
				t.Fatalf("member unlink of a foreign link: %v", err)
			}
		})
	}
}

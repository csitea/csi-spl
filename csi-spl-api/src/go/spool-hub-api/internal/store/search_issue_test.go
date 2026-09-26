package store

import (
	"reflect"
	"strconv"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/search"
)

// The search grammar's issue sets are store's, not a copy (1.2, CLE-34992).
// CONTROL: every workflow status parses as status:, a value outside it does not.
func TestSearchIssueSetsAreStores(t *testing.T) {
	if !reflect.DeepEqual(search.IssueStatuses, IssueStatuses) || search.IssuePriorityMax != IssuePriorityMax || search.IssuePriorityMin != IssuePriorityMin {
		t.Fatalf("search %v / %d..%d, store %v / %d..%d", search.IssueStatuses, search.IssuePriorityMin, search.IssuePriorityMax,
			IssueStatuses, IssuePriorityMin, IssuePriorityMax)
	}
	// the store's own mapping of older names, not a copy
	for _, old := range []string{"backlog", "in_progress", "in_review", "canceled"} {
		if search.IssueStatusNormalize == nil || search.IssueStatusNormalize(old) != NormalizeIssueStatus(old) || !ValidIssueStatus(NormalizeIssueStatus(old)) {
			t.Fatalf("normalize %q", old)
		}
		if _, err := search.Parse("status:"+old, time.Now()); err != nil {
			t.Errorf("older name status:%s: %v", old, err)
		}
	}
	for _, p := range []string{"prio=" + strconv.Itoa(IssuePriorityMin), "prio=" + strconv.Itoa(IssuePriorityMax)} {
		if _, err := search.Parse(p, time.Now()); err != nil {
			t.Errorf("%s: %v", p, err)
		}
	}
	if _, err := search.Parse("prio="+strconv.Itoa(IssuePriorityMin-1), time.Now()); err == nil {
		t.Error("a prio below the store's minimum must be a bad query")
	}
	for _, s := range IssueStatuses {
		if !ValidIssueStatus(s) {
			t.Fatalf("store rejects its own %q", s)
		}
		if _, err := search.Parse("status:"+s, time.Now()); err != nil {
			t.Errorf("status:%s: %v", s, err)
		}
	}
	if _, err := search.Parse("status:open", time.Now()); err == nil {
		t.Error("status:open must be a bad query")
	}
}

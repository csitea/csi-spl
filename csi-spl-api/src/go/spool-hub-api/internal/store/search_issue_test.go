package store

import (
	"reflect"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/search"
)

// The search grammar's issue sets are store's, not a copy (1.2, CLE-34992).
// CONTROL: every workflow status parses as status:, a value outside it does not.
func TestSearchIssueSetsAreStores(t *testing.T) {
	if !reflect.DeepEqual(search.IssueStatuses, IssueStatuses) || search.IssuePriorityMax != IssuePriorityMax {
		t.Fatalf("search %v / %d, store %v / %d", search.IssueStatuses, search.IssuePriorityMax, IssueStatuses, IssuePriorityMax)
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

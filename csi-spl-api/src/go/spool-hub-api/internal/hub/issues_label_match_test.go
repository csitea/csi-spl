package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Spec 097 T17 (SPL-5883): ?label=a,b matches any label by default and
// every label with ?label_match=all, the To-do view's filter.
func TestIssuesLabelMatchAll(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	for _, name := range []string{"a", "b"} {
		if code, out := call(t, e, tid, http.MethodPost, "/v1/issue-labels", dev, map[string]string{"name": name}); code != http.StatusCreated {
			t.Fatalf("label %s: %d %v", name, code, out)
		}
	}
	for _, labels := range [][]string{{"a"}, {"b"}, {"a", "b"}, {}} { // SPL-1..SPL-4
		if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "x", "labels": labels}); code != http.StatusCreated {
			t.Fatalf("issue %v: %d %v", labels, code, out)
		}
	}
	for q, want := range map[string][]string{
		"label=a,b":                 {"SPL-3", "SPL-2", "SPL-1"}, // unchanged: either label
		"label=a,b&label_match=any": {"SPL-3", "SPL-2", "SPL-1"},
		"label=a,b&label_match=all": {"SPL-3"},
		"label=a&label_match=all":   {"SPL-3", "SPL-1"},
		"label_match=all":           {"SPL-4", "SPL-3", "SPL-2", "SPL-1"}, // no label: no filter
	} {
		code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues?sort=created&"+q, dev, nil)
		if code != http.StatusOK || !sameKeys(issueKeys(out), want...) {
			t.Errorf("%s: %d %v want %v", q, code, issueKeys(out), want)
		}
	}
	if code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues?label=a&label_match=every", dev, nil); code != http.StatusBadRequest {
		t.Errorf("label_match=every: %d %v, want 400", code, out)
	}
}

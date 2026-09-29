package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// W16 (spec 047, SPL-1175): the first issue of a tenant needs no epic, and
// the key prefix is a Tenant settings -> General field.
func TestIssueWithoutEpicAndPrefix(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	owner := seat(t, e, tid, rbac.BizOwner)
	dev := seat(t, e, tid, rbac.Developer)

	code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "First thing"})
	one := issueOf(t, out)
	if code != http.StatusCreated || one["key"] != "SPL-1" || one["epic"] != "" || one["parent"] != "" || one["level"] != float64(2) {
		t.Fatalf("first issue without an epic: %d %v", code, out)
	}
	code, out = call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "a step", "parent": "SPL-1"})
	if sub := issueOf(t, out); code != http.StatusCreated || sub["level"] != float64(3) || sub["kind"] != "subtask" {
		t.Fatalf("subtask of a lone issue: %d %v", code, out)
	}

	code, body := call(t, e, tid, http.MethodGet, "/v1/tenant/settings", owner, nil)
	if code != 200 || body["issue_prefix"] != "SPL" {
		t.Fatalf("default prefix: %d %v", code, body)
	}
	for _, bad := range []string{"", "1AB", "A-B", "ABCDEFGHIJK"} {
		if code, body := call(t, e, tid, http.MethodPatch, "/v1/tenant/settings", owner, map[string]any{"issue_prefix": bad}); code != http.StatusBadRequest || body["error"] != "bad_setting" {
			t.Errorf("prefix %q: %d %v, want 400 bad_setting", bad, code, body)
		}
	}
	// Control: a developer may file issues but not rename every key.
	if code, _ := call(t, e, tid, http.MethodPatch, "/v1/tenant/settings", dev, map[string]any{"issue_prefix": "DEV"}); code != http.StatusForbidden {
		t.Fatalf("developer prefix change: %d, want 403", code)
	}
	code, body = call(t, e, tid, http.MethodPatch, "/v1/tenant/settings", owner, map[string]any{"issue_prefix": " acme "})
	if code != 200 || body["issue_prefix"] != "ACME" {
		t.Fatalf("set prefix: %d %v", code, body)
	}
	code, out = call(t, e, tid, http.MethodGet, "/v1/view/issues", dev, nil)
	if code != 200 || !sameKeys(issueKeys(out), "ACME-2", "ACME-1") {
		t.Fatalf("keys after the prefix change: %d %v", code, issueKeys(out))
	}
	code, out = call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "next"})
	if code != http.StatusCreated || issueOf(t, out)["key"] != "ACME-3" {
		t.Fatalf("new key: %d %v", code, out)
	}
}

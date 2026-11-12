package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-5359 (spec 123 16, rdb 0275): an internal_accountant of the OPERATOR
// workspace reads the cost report (200), lists (200), creates (201) and
// deletes (204) a cost entry, and is refused a member role change (403
// members.roles) and an operator write (PATCH /v1/operator/fleet-load, 403
// operator.workspaces). The same role in another workspace writes no entry:
// the rows are the estate's (403). An external_accountant holds no
// topics.read, so every browser door refuses it (403 topics.read) until a
// costs-only door exists (spec 123 16, the open follow-up). RED CONTROL:
// without costEntryGate in costEntryCaller the operator accountant's list,
// create and delete answer 403 operator.workspaces.
func TestCostEntryAccountantRoles(t *testing.T) {
	r := newFleetTokensRig(t)
	entry := map[string]any{"type": "hr", "label": "contract staff", "amount": 3100, "currency": "EUR", "period": "2020-05", "note": "test fixture"}
	acc := seat(t, r.e, r.op, rbac.InternalAccountant)
	if code, got := call(t, r.e, r.op, http.MethodGet, "/v1/tenant/costs", acc, nil); code != http.StatusOK {
		t.Errorf("cost report: %d %v, want 200", code, got)
	}
	if code, got := call(t, r.e, r.op, http.MethodGet, costEntryPath+"?type=hr", acc, nil); code != http.StatusOK || got["entries"] == nil {
		t.Errorf("list: %d %v, want 200", code, got)
	}
	code, got := call(t, r.e, r.op, http.MethodPost, costEntryPath, acc, entry)
	id, _ := got["id"].(string)
	if code != http.StatusCreated || id == "" || got["created_by"] != acc || got["type"] != "hr" {
		t.Fatalf("create: %d %v, want 201", code, got)
	}
	if code, got := call(t, r.e, r.op, http.MethodDelete, costEntryPath+"/"+id, acc, nil); code != http.StatusNoContent {
		t.Errorf("delete: %d %v, want 204", code, got)
		call(t, r.e, r.op, http.MethodDelete, costEntryPath+"/"+id, r.admin, nil)
	}
	if code, got := call(t, r.e, r.op, http.MethodPut, "/v1/members/"+r.dev+"/roles", acc,
		map[string]any{"roles": []string{rbac.Tester}}); code != http.StatusForbidden || got["permission"] != rbac.MembersRoles {
		t.Errorf("member role change: %d %v, want 403 members.roles", code, got)
	}
	if code, got := call(t, r.e, r.op, http.MethodPatch, "/v1/operator/fleet-load", acc,
		map[string]any{"max_agents": 1}); code != http.StatusForbidden || got["permission"] != "operator.workspaces" {
		t.Errorf("operator write: %d %v, want 403 operator.workspaces", code, got)
	}
	other := seat(t, r.e, r.other, rbac.InternalAccountant)
	if code, got := call(t, r.e, r.other, http.MethodPost, costEntryPath, other, entry); code != http.StatusForbidden {
		t.Errorf("another workspace's accountant create: %d %v, want 403", code, got)
	}
	ext := seat(t, r.e, r.op, rbac.ExternalAccountant)
	for _, rt := range [][2]string{{http.MethodGet, "/v1/tenant/costs"}, {http.MethodGet, costEntryPath}, {http.MethodPost, costEntryPath}} {
		var body any
		if rt[0] == http.MethodPost {
			body = entry
		}
		if code, got := call(t, r.e, r.op, rt[0], rt[1], ext, body); code != http.StatusForbidden || got["permission"] != rbac.TopicsRead {
			t.Errorf("external_accountant %s %s: %d %v, want 403 topics.read (no costs-only door yet)", rt[0], rt[1], code, got)
		}
	}
}

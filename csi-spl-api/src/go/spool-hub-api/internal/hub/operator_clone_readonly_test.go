package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-5369 (owner HUM-10, t1 8426e63e, pick A): a live act-as clone of the
// operator admin READS the operator routes but WRITES none of them. Every
// write aims at a target that does not exist or a body the route refuses, so
// the admin's control proves only that the gate lets it through.

// opRoute is one operator route on the session path (operatorActor).
type opRoute struct {
	method, path string
	body         any
}

// operatorCloneWrites are the operator writes that are not paid items or
// cost entries (those are TestOperatorWriteActAsClone's).
func operatorCloneWrites(op string) []opRoute {
	nope := newTenantID("nope")
	return []opRoute{
		{http.MethodPatch, "/v1/operator/fleet-load", map[string]any{}},
		{http.MethodPost, "/v1/operator/categories", map[string]any{}},
		{http.MethodPut, "/v1/operator/categories/nope", map[string]any{}},
		{http.MethodPut, "/v1/operator/incomes", map[string]any{}},
		{http.MethodPut, "/v1/operator/fleet-desks/nope", map[string]any{}},
		{http.MethodDelete, "/v1/operator/fleet-desks/nope", nil},
		{http.MethodPost, "/v1/operator/workspaces", map[string]any{}},
		{http.MethodPatch, "/v1/operator/workspaces/" + nope, map[string]any{}},
		{http.MethodDelete, "/v1/operator/workspaces/" + nope, nil},
		{http.MethodPut, "/v1/operator/workspaces/" + op + "/agent-caps", map[string]any{}},
		{http.MethodDelete, "/v1/operator/workspaces/" + op + "/agent-caps/nope", nil},
		{http.MethodPost, "/v1/operator/events/delete", map[string]any{}},
	}
}

// operatorCloneReads are the operator reads on the same gate; the lane
// console's POST is a watch demand, a read.
func operatorCloneReads(op string) []opRoute {
	return []opRoute{
		{http.MethodGet, "/v1/operator/fleet-load", nil},
		{http.MethodGet, "/v1/operator/fleet-desks", nil},
		{http.MethodGet, "/v1/operator/fleet-roster", nil},
		{http.MethodGet, "/v1/operator/zombie-topics", nil},
		{http.MethodGet, "/v1/reporting/tokens/by-category", nil},
		{http.MethodGet, "/v1/operator/workspaces", nil},
		{http.MethodGet, "/v1/operator/workspaces/" + op, nil},
		{http.MethodGet, "/v1/operator/workspaces/" + op + "/agent-caps", nil},
		{http.MethodGet, "/v1/operator/events", nil},
		{http.MethodGet, "/v1/operator/lane-console?agent_id=c-001&agent_box=nope", nil},
		{http.MethodPost, "/v1/operator/lane-console", map[string]any{"agent_id": "c-001", "agent_box": "nope"}},
	}
}

// TestOperatorRoutesActAsCloneReadOnly: the admin's live clone gets 403
// operator.workspaces on every write and, on every read, the admin's own
// answer. CONTROL: the admin is never refused a write, and a developer (no
// clone) is refused all of them.
func TestOperatorRoutesActAsCloneReadOnly(t *testing.T) {
	e, op, _, who, _, _ := costReadEnv(t)
	cs, ok := e.st.(dmCloneStore)
	if !ok {
		t.Skip("act-as clone store needs Postgres (SPOOL_TEST_PG_DSN)")
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	cl, err := cs.StartClone(context.Background(), store.CloneStart{TenantID: op, TargetHum: who[rbac.Admin], AdminName: "Admin",
		CreatedBy: who[rbac.Admin], ExpiresAt: now.Add(time.Hour)}, now)
	if err != nil {
		t.Fatal(err)
	}
	for _, w := range operatorCloneWrites(op) {
		if code, got := call(t, e, op, w.method, w.path, cl.CloneHum, w.body); code != http.StatusForbidden || got["permission"] != "operator.workspaces" {
			t.Errorf("clone %s %s: %d %v, want 403 operator.workspaces", w.method, w.path, code, got)
		}
		if code, got := call(t, e, op, w.method, w.path, who[rbac.Developer], w.body); code != http.StatusForbidden {
			t.Errorf("CONTROL developer %s %s: %d %v, want 403", w.method, w.path, code, got)
		}
		if code, got := call(t, e, op, w.method, w.path, who[rbac.Admin], w.body); code == http.StatusForbidden {
			t.Errorf("CONTROL admin %s %s: %d %v, want not 403", w.method, w.path, code, got)
		}
	}
	for _, rd := range operatorCloneReads(op) {
		want, _ := call(t, e, op, rd.method, rd.path, who[rbac.Admin], rd.body)
		code, got := call(t, e, op, rd.method, rd.path, cl.CloneHum, rd.body)
		if code == http.StatusForbidden || code != want {
			t.Errorf("clone %s %s: %d %v, want the admin's %d", rd.method, rd.path, code, got, want)
		}
		t.Logf("clone %s %s: %d", rd.method, rd.path, code)
	}
}

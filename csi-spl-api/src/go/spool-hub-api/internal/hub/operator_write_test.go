package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-5348: a live act-as clone may not write what it may not read
// (SPL-5181). Every write route of the operator's paid items and cost entries
// refuses a clone of the operator admin and of its product owner.

// operatorWrite is one write route and the code the admin gets on it.
type operatorWrite struct {
	method, path string
	body         any
	want         int
}

// operatorWrites are the 5 writes; PATCH and DELETE aim at paid item paid
// and cost entry ce.
func operatorWrites(paid, ce string) []operatorWrite {
	return []operatorWrite{
		{http.MethodPost, costEntryPath, map[string]any{"type": "hr", "label": "x", "amount": 1, "currency": "EUR", "period": "2011-03"}, http.StatusCreated},
		{http.MethodDelete, costEntryPath + "/" + ce, nil, http.StatusNoContent},
		{http.MethodPost, fleetPaidPath, map[string]any{"vendor": "agy", "kind": "subscription", "plan_label": "agy monthly", "amount": 20, "currency": "USD",
			"period_start": "2011-03-01", "period_end": "2011-03-31"}, http.StatusCreated},
		{http.MethodPatch, fleetPaidPath + "/" + paid, map[string]any{"quantity": 2}, http.StatusOK},
		{http.MethodDelete, fleetPaidPath + "/" + paid, nil, http.StatusNoContent},
	}
}

// operatorWriteDone posts w as hum and removes what a 201 created at cleanup.
func operatorWriteDone(t *testing.T, e *env, op, hum string, w operatorWrite) (int, map[string]any) {
	t.Helper()
	code, got := call(t, e, op, w.method, w.path, hum, w.body)
	if id, _ := got["id"].(string); code == http.StatusCreated && id != "" {
		t.Cleanup(func() { call(t, e, op, http.MethodDelete, w.path+"/"+id, hum, nil) })
	}
	return code, got
}

// TestOperatorWriteActAsClone: a live clone of the operator admin or product
// owner gets 403 operator.workspaces on each write. CONTROL: a developer of
// the operator workspace (no clone) is refused the same 5, and the admin
// then writes all 5, so the item and entry the clones aimed at were left.
func TestOperatorWriteActAsClone(t *testing.T) {
	e, op, _, who, _, _ := costReadEnv(t)
	cs, ok := e.st.(dmCloneStore)
	if !ok {
		t.Skip("act-as clone store needs Postgres (SPOOL_TEST_PG_DSN)")
	}
	seed := operatorWrites("", "")
	_, entry := operatorWriteDone(t, e, op, who[rbac.Admin], seed[0])
	_, item := operatorWriteDone(t, e, op, who[rbac.Admin], seed[2])
	ce, _ := entry["id"].(string)
	paid, _ := item["id"].(string)
	if ce == "" || paid == "" {
		t.Fatalf("CONTROL seed: entry %v, item %v", entry, item)
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	for _, role := range []string{rbac.Admin, rbac.ProductOwner, rbac.Developer} {
		hum := who[role]
		if role != rbac.Developer {
			cl, err := cs.StartClone(context.Background(), store.CloneStart{TenantID: op, TargetHum: hum, AdminName: "Admin",
				CreatedBy: who[rbac.Admin], ExpiresAt: now.Add(time.Hour)}, now)
			if err != nil {
				t.Fatal(err)
			}
			hum = cl.CloneHum
		}
		for _, w := range operatorWrites(paid, ce) {
			if code, got := operatorWriteDone(t, e, op, hum, w); code != http.StatusForbidden || got["permission"] != "operator.workspaces" {
				t.Errorf("%s (a clone unless developer) %s %s: %d %v, want 403 operator.workspaces", role, w.method, w.path, code, got)
			}
		}
	}
	for _, w := range operatorWrites(paid, ce) {
		if code, got := operatorWriteDone(t, e, op, who[rbac.Admin], w); code != w.want {
			t.Errorf("CONTROL admin %s %s: %d %v, want %d", w.method, w.path, code, got, w.want)
		}
	}
}

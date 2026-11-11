package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

const (
	costAllocOpPath     = "/v1/operator/cost-allocations"
	costAllocTenantPath = "/v1/tenant/cost-allocations"
)

// seatAs admits the person of email into tid with role: the same email in
// two workspaces is one person with two memberships.
func seatAs(t *testing.T, e *env, tid, email, role string) string {
	t.Helper()
	h := e.st.(store.Humans)
	now := time.Now()
	if err := h.PutInvite(context.Background(), store.Invite{TenantID: tid, Email: email, Role: role,
		InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	hum, err := h.Admit(context.Background(), store.Identity{Provider: "google", Subject: "s-" + email, Email: email}, tid, store.AdmitPolicy{}, now)
	if err != nil {
		t.Fatal(err)
	}
	return hum
}

func allocBody(label string, shares ...[2]any) map[string]any {
	out := []map[string]any{}
	for _, s := range shares {
		out = append(out, map[string]any{"workspace_id": s[0], "share_bp": s[1]})
	}
	return map[string]any{"source": "cost_entry", "project_or_vendor": label, "kind": "cloud", "shares": out}
}

// allocatedPart is the allocated part of label in tid's month answer as hum.
func allocatedPart(t *testing.T, r *fleetTokensRig, tid, hum, month, label string) (entryCostPart, bool) {
	t.Helper()
	b := entryMonthRead(t, r, tid, hum, month)
	for _, p := range b.Parts {
		if p.Source == "allocated" && p.ProjectOrVendor == label {
			return p, true
		}
	}
	return entryCostPart{}, false
}

// SPL-5291 (owner HUM-10 poll 01cbbdea, 1B 2B 3B; spec 143
// costs-allocation.md sections 3 and 4). A1 only the operator admin sets a
// split on the operator door (the operator developer and another
// workspace's admin: 403); a Tokens item and a sum of 9999 are 400. A2 a
// person who is admin of W1 and W2 and developer of W3 sees only W1's and
// W2's shares (held 8000, never W3's) and re-splits 40/40 to 20/60 with a
// body of W1 and W2 only, as that view gives it; W3 keeps 2000. A3 the
// same person changing W3's share is 403 cost_allocation.outside; from W3
// (a developer there) and as W1's developer the door is 403. A4 W2's month
// answer holds its share of the item as source allocated, floor(amount *
// 6000 / 10000), in the item's month AND an earlier one (a split holds for
// every month); a workspace outside the split has no such part; the
// estate answer keeps the whole amount and names the split.
// RED CONTROL: costAllocAdminSet without the a.Has(rbac.Admin) check
// counts W3 (a developer there) as administered: A2 then shows W3's share
// and fails (run 2026-11-11, memory store).
func TestCostAllocationRoutes(t *testing.T) {
	r := newFleetTokensRig(t)
	w1, _ := r.e.tenant()
	w2, _ := r.e.tenant()
	w3, _ := r.e.tenant()
	email := newTenantID("p") + "@example.com"
	p := seatAs(t, r.e, w1, email, rbac.Admin)
	seatAs(t, r.e, w2, email, rbac.Admin)
	seatAs(t, r.e, w3, email, rbac.Developer)
	devW1 := seat(t, r.e, w1, rbac.Developer)
	label := "shared bill " + newTenantID("b")
	for _, m := range []string{"2004-05", "2004-06"} {
		code, got := call(t, r.e, r.op, http.MethodPost, costEntryPath, r.admin,
			map[string]any{"type": "cloud", "label": label, "amount": 100, "currency": "USD", "period": m})
		if code != http.StatusCreated {
			t.Fatalf("entry %s: %d %v", m, code, got)
		}
		id, _ := got["id"].(string)
		t.Cleanup(func() { call(t, r.e, r.op, http.MethodDelete, costEntryPath+"/"+id, r.admin, nil) })
	}
	split := allocBody(label, [2]any{w1, 4000}, [2]any{w2, 4000}, [2]any{w3, 2000})
	// A1
	for name, who := range map[string][2]string{"operator developer": {r.op, r.dev}, "other workspace admin": {r.other, r.otherA}} {
		if code, got := call(t, r.e, who[0], http.MethodPut, costAllocOpPath, who[1], split); code != http.StatusForbidden {
			t.Errorf("A1 %s: %d %v, want 403", name, code, got)
		}
	}
	tokens := map[string]any{"source": "ai_paid", "project_or_vendor": "claude", "kind": "max",
		"shares": []map[string]any{{"workspace_id": w1, "share_bp": 10000}}}
	for name, b := range map[string]map[string]any{"tokens": tokens, "sum 9999": allocBody(label, [2]any{w1, 9999})} {
		if code, got := call(t, r.e, r.op, http.MethodPut, costAllocOpPath, r.admin, b); code != http.StatusBadRequest {
			t.Errorf("A1 %s: %d %v, want 400", name, code, got)
		}
	}
	if code, got := call(t, r.e, r.op, http.MethodPut, costAllocOpPath, r.admin, split); code != http.StatusOK {
		t.Fatalf("A1 operator split: %d %v", code, got)
	}
	t.Cleanup(func() { call(t, r.e, r.op, http.MethodPut, costAllocOpPath, r.admin, allocBody(label)) })
	// A2
	code, got := call(t, r.e, w1, http.MethodGet, costAllocTenantPath+"?month=2004-06", p, nil)
	if code != http.StatusOK {
		t.Fatalf("A2 list: %d %v", code, got)
	}
	held := heldItem(got, label)
	if held == nil || held["held_bp"] != float64(8000) || len(held["shares"].([]any)) != 2 {
		t.Fatalf("A2 the person's view: %v", held)
	}
	for _, s := range held["shares"].([]any) {
		if s.(map[string]any)["workspace_id"] == w3 {
			t.Fatalf("A2 W3's share is shown: %v", held)
		}
	}
	resplit := allocBody(label, [2]any{w1, 2000}, [2]any{w2, 6000})
	if code, got := call(t, r.e, w1, http.MethodPut, costAllocTenantPath, p, resplit); code != http.StatusOK {
		t.Fatalf("A2 re-split: %d %v", code, got)
	}
	code, got = call(t, r.e, r.op, http.MethodGet, costAllocOpPath+"?month=2004-06", r.admin, nil)
	stored := map[string]float64{}
	if it := heldItem(got, label); code == http.StatusOK && it != nil {
		for _, s := range it["shares"].([]any) {
			sh := s.(map[string]any)
			stored[sh["workspace_id"].(string)] = sh["share_bp"].(float64)
		}
	}
	if stored[w1] != 2000 || stored[w2] != 6000 || stored[w3] != 2000 || len(stored) != 3 {
		t.Fatalf("A2 the stored split after the admin's re-split: %d %v, want W1 2000 W2 6000 W3 2000", code, stored)
	}
	// A3
	if code, got := call(t, r.e, w1, http.MethodPut, costAllocTenantPath, p,
		allocBody(label, [2]any{w1, 2000}, [2]any{w2, 7000}, [2]any{w3, 1000})); code != http.StatusForbidden || got["error"] != "cost_allocation.outside" {
		t.Errorf("A3 W3 changed: %d %v, want 403 cost_allocation.outside", code, got)
	}
	for name, who := range map[string][2]string{"from W3": {w3, p}, "W1 developer": {w1, devW1}} {
		if code, got := call(t, r.e, who[0], http.MethodPut, costAllocTenantPath, who[1], resplit); code != http.StatusForbidden {
			t.Errorf("A3 %s: %d %v, want 403", name, code, got)
		}
	}
	// A4
	w2Admin := seat(t, r.e, w2, rbac.Admin)
	for _, m := range []string{"2004-05", "2004-06"} {
		part, ok := allocatedPart(t, r, w2, w2Admin, m, label)
		if !ok || part.USDMicros != 60_000_000 {
			t.Errorf("A4 W2 %s: %+v %v, want 60 USD allocated", m, part, ok)
		}
	}
	if _, ok := allocatedPart(t, r, r.other, r.otherA, "2004-06", label); ok {
		t.Error("A4 a workspace outside the split reads a share of it")
	}
	b := entryMonthRead(t, r, r.op, r.admin, "2004-06")
	if e, ok := entryByLabel(b.Parts, label); !ok || e.USDMicros != 100_000_000 {
		t.Errorf("A4 the estate's item: %+v %v, want the whole 100 USD", e, ok)
	}
}

// heldItem is label's item of a tenant cost-allocations answer.
func heldItem(got map[string]any, label string) map[string]any {
	items, _ := got["items"].([]any)
	for _, it := range items {
		m := it.(map[string]any)
		if m["project_or_vendor"] == label {
			return m
		}
	}
	return nil
}

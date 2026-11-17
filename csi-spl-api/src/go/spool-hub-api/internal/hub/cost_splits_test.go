package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

const costSplitPath = "/v1/operator/cost-splits"

func splitBody(kind, subject string, shares ...[2]any) map[string]any {
	out := []map[string]any{}
	for _, s := range shares {
		out = append(out, map[string]any{"workspace_id": s[0], "share_bp": s[1]})
	}
	return map[string]any{"split_kind": kind, "subject": subject, "shares": out}
}

// splitMonth is the part of the month answer the split test reads.
type splitMonth struct {
	Parts []struct {
		Source          string                 `json:"source"`
		ProjectOrVendor string                 `json:"project_or_vendor"`
		Kind            string                 `json:"kind"`
		USDMicros       int64                  `json:"usd_micros"`
		AllocatedSource string                 `json:"allocated_source"`
		ShareBP         int                    `json:"share_bp"`
		Allocation      []store.CostAllocShare `json:"allocation"`
	} `json:"parts"`
	Human []struct {
		Source          string                 `json:"source"`
		ProjectOrVendor string                 `json:"project_or_vendor"`
		Component       string                 `json:"component"`
		EntryMicros     int64                  `json:"entry_micros"`
		ShareBP         int                    `json:"share_bp"`
		Allocation      []store.CostAllocShare `json:"allocation"`
	} `json:"human"`
}

func splitMonthRead(t *testing.T, r *fleetTokensRig, tid, hum, month string) (splitMonth, string) {
	t.Helper()
	code, body := call(t, r.e, tid, http.MethodGet, "/v1/tenant/costs?month="+month, hum, nil)
	raw, _ := json.Marshal(body)
	if code != http.StatusOK {
		t.Fatalf("costs in %s: %d %s", tid, code, raw)
	}
	var b splitMonth
	if err := json.Unmarshal(raw, &b); err != nil {
		t.Fatal(err)
	}
	return b, string(raw)
}

// humanOf is the EntryMicros, share and item label of b's Human row of
// source for component (-1 = none).
func humanOf(b splitMonth, source, component string) (int64, int, string) {
	for _, h := range b.Human {
		if h.Source == source && h.Component == component {
			return h.EntryMicros, h.ShareBP, h.ProjectOrVendor
		}
	}
	return -1, 0, ""
}

// SPL-5768 (owner HUM-10, csitea f655b326 msg 3440bf12; spec 143
// costs-allocation.md section 7), made-up figures in 2008-02 (no other test
// uses it). S1 the operator workspace's developer and another workspace's
// admin get 403 on both doors; S2 a sum of 9999, a tokens split with a
// subject and a person split of no hr person are 400; S3 the operator's
// biz_owner sets the person split op 3000 / W 7000 and the tokens split op
// 7000 / W 3000, and the GET lists both and the person by id and code; S4 W
// reads its 70 % of the person's hr line as an allocated Human row, and an
// item split of that line (W 10000) wins over the person split; S5 W reads
// its 30 % of the paid AI item as one ai_share part per agent type, no plan
// in the answer; S6 the estate keeps the full amounts and names both
// splits. RED CONTROL: costReadGather without the costSplitAIParts branch,
// W has no ai_share part and S5 fails (run 2026-11-17, memory store).
func TestCostSplitRoutes(t *testing.T) {
	r := newFleetTokensRig(t)
	const month = "2008-02"
	w := r.other
	biz := seat(t, r.e, r.op, rbac.BizOwner)
	acc := seat(t, r.e, r.op, rbac.InternalAccountant)
	reopenMonth(t, r, month)
	code := "S-" + digits4(newTenantID(""))
	c, got := call(t, r.e, r.op, http.MethodPost, "/v1/operator/hr-people", acc,
		map[string]any{"code": code, "name": "FirstName LastName", "employment_type": "employee"})
	pid, _ := got["id"].(string)
	if c != http.StatusCreated || pid == "" {
		t.Fatalf("person: %d %v", c, got)
	}
	if c, got := call(t, r.e, r.op, http.MethodPost, costEntryPath, acc, map[string]any{"type": "hr", "label": "split line",
		"currency": "EUR", "period": month, "person_id": pid, "component": "monthly_salary", "amount": 1000, "source": "payslip"}); c != http.StatusCreated {
		t.Fatalf("hr line: %d %v", c, got)
	}
	fp := r.e.st.(store.FleetPaidStore)
	plan := "plan-" + newTenantID("p")
	it, err := fp.CreatePaidItem(context.Background(), store.FleetPaidItem{Vendor: "claude", Kind: "subscription",
		PlanLabel: plan, Quantity: 1, Amount: 290, Currency: "USD", PeriodStart: month + "-01",
		PeriodEnd: month + "-29", CreatedBy: "split-test"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = fp.DeletePaidItem(context.Background(), it.ID) })
	person := splitBody("person", pid, [2]any{r.op, 3000}, [2]any{w, 7000})
	tokens := splitBody("tokens", "", [2]any{r.op, 7000}, [2]any{w, 3000})
	// S1
	for name, who := range map[string][2]string{"operator developer": {r.op, r.dev}, "other workspace admin": {w, r.otherA}} {
		if c, got := call(t, r.e, who[0], http.MethodPut, costSplitPath, who[1], tokens); c != http.StatusForbidden {
			t.Errorf("S1 %s PUT: %d %v, want 403", name, c, got)
		}
		if c, got := call(t, r.e, who[0], http.MethodGet, costSplitPath, who[1], nil); c != http.StatusForbidden {
			t.Errorf("S1 %s GET: %d %v, want 403", name, c, got)
		}
	}
	// S2
	for name, b := range map[string]map[string]any{"sum 9999": splitBody("tokens", "", [2]any{w, 9999}),
		"tokens subject": splitBody("tokens", pid, [2]any{w, 10000}),
		"no hr person":   splitBody("person", "no-such-person", [2]any{w, 10000}),
		"kind":           splitBody("cloud", "", [2]any{w, 10000})} {
		if c, got := call(t, r.e, r.op, http.MethodPut, costSplitPath, r.admin, b); c != http.StatusBadRequest {
			t.Errorf("S2 %s: %d %v, want 400", name, c, got)
		}
	}
	// S3
	for _, b := range []map[string]any{person, tokens} {
		if c, got := call(t, r.e, r.op, http.MethodPut, costSplitPath, biz, b); c != http.StatusOK {
			t.Fatalf("S3 biz_owner PUT %v: %d %v", b["split_kind"], c, got)
		}
	}
	t.Cleanup(func() {
		call(t, r.e, r.op, http.MethodPut, costSplitPath, r.admin, splitBody("tokens", ""))
		call(t, r.e, r.op, http.MethodPut, costSplitPath, r.admin, splitBody("person", pid))
	})
	c, got = call(t, r.e, r.op, http.MethodGet, costSplitPath, r.admin, nil)
	raw, _ := json.Marshal(got)
	if c != http.StatusOK || !strings.Contains(string(raw), pid) || !strings.Contains(string(raw), code) ||
		len(got["splits"].([]any)) < 2 || strings.Contains(string(raw), "FirstName") {
		t.Fatalf("S3 GET: %d %s", c, raw)
	}
	// S4
	b, _ := splitMonthRead(t, r, w, r.otherA, month)
	if m, bp, _ := humanOf(b, "allocated", "monthly_salary"); m != 700_000_000 || bp != 7000 {
		t.Fatalf("S4 W's share of the person's line: %d micros at %d bp, want 700000000 at 7000", m, bp)
	}
	est, _ := splitMonthRead(t, r, r.op, r.admin, month)
	whole, _, item := humanOf(est, "cost_entry", "monthly_salary")
	if whole != 1_000_000_000 {
		t.Fatalf("S6 the estate's hr row: %d micros, want the whole 1000000000", whole)
	}
	// the item split of the estate's row, straight into the store: the
	// route checks an hr label against the raw lines, not the row's
	ca := r.e.st.(store.CostAllocationStore)
	key := store.CostItemKey{Source: "cost_entry", ProjectOrVendor: item, Kind: "hr"}
	if _, err := ca.PutCostAllocation(context.Background(), store.CostAllocation{CostItemKey: key,
		Shares: []store.CostAllocShare{{WorkspaceID: w, ShareBP: 10000}}, CreatedBy: "split-test"}, nil); err != nil {
		t.Fatal(err)
	}
	b, _ = splitMonthRead(t, r, w, r.otherA, month)
	if m, bp, _ := humanOf(b, "allocated", "monthly_salary"); m != 1_000_000_000 || bp != 10000 {
		t.Errorf("S4 the item split does not win: %d micros at %d bp, want 1000000000 at 10000 once", m, bp)
	}
	if _, err := ca.PutCostAllocation(context.Background(), store.CostAllocation{CostItemKey: key, CreatedBy: "split-test"}, nil); err != nil {
		t.Fatal(err)
	}
	// S5, S6
	var paid int64
	for _, p := range est.Parts {
		if p.Source == store.CostSourceAIPaid && p.Kind == plan {
			paid = p.USDMicros
			if store.ShareOf(p.Allocation, w) != 3000 {
				t.Errorf("S6 the estate's paid part names no tokens split: %+v", p.Allocation)
			}
		}
	}
	if paid <= 0 {
		t.Fatalf("S6 the estate reads no paid part of %s", plan)
	}
	b, raw2 := splitMonthRead(t, r, w, r.otherA, month)
	var share int64
	for _, p := range b.Parts {
		if p.Source == store.CostSourceAIPaid {
			t.Fatalf("S5 W's answer carries an ai_paid part: %s", raw2)
		}
		if p.Source == store.CostSourceAIShare && p.ProjectOrVendor == "claude" && p.Kind == "share" && p.ShareBP == 3000 {
			share += p.USDMicros
		}
	}
	_, onMemory := r.e.st.(*store.Memory)
	if strings.Contains(raw2, plan) || share <= 0 || (onMemory && share != store.CostAllocShareOf(paid, 3000)) {
		t.Fatalf("S5 W's tokens share %d (estate %d), want floor of 30 %%, no plan: %s", share, paid, raw2)
	}
}

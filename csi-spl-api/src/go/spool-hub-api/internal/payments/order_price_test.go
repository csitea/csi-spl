package payments

import (
	"encoding/json"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 181 4.1 step 2 (SPL-6339): the plan read shows the private-workspace
// price before the order -- seat_member_cents and vm_margin_pct from the
// store constants (B1) -- and carries NO VM cost estimate field (no machine
// type or price is settled, spec 122 RQ-3 is open). RED CONTROL: the read's numbers
// and the order submit's 201 numbers must be the same; a divergence fails.
func TestPlanShowsPrivateWorkspacePrice(t *testing.T) {
	h, _, _ := orderHandler(t, &countingRail{})
	w := httptest.NewRecorder()
	h.ServeHTTP(w, httptest.NewRequest("GET", RoutePrefix+"/plan", nil))
	var plan struct {
		PrivateWorkspace map[string]any `json:"private_workspace"`
	}
	if err := json.Unmarshal(w.Body.Bytes(), &plan); err != nil || w.Code != 200 {
		t.Fatalf("plan: %d %s %v", w.Code, w.Body, err)
	}
	pw := plan.PrivateWorkspace
	if pw["seat_member_cents"] != float64(store.PrivateVMSeatCents) || pw["vm_margin_pct"] != float64(store.PrivateVMMarginPct) ||
		pw["currency"] != store.PlanCurrency || len(pw) != 3 {
		t.Fatalf("private_workspace = %v, want exactly currency, seat_member_cents %d, vm_margin_pct %d",
			pw, store.PrivateVMSeatCents, store.PrivateVMMarginPct)
	}
	for k := range pw {
		if strings.Contains(k, "estimate") || strings.Contains(k, "vm_cost") {
			t.Fatalf("private_workspace carries an estimate field %q: none is settled (spec 122 RQ-3)", k)
		}
	}
	code, out := postOrder(h, orderBody)
	if code != 201 {
		t.Fatalf("submit: %d %v", code, out)
	}
	for k, v := range pw {
		if out[k] != v {
			t.Errorf("%s: plan read %v, order submit %v: the price shown before the order must be the one it takes", k, v, out[k])
		}
	}
}

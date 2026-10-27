package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// aiCostBody is the part of GET /v1/tenant/costs the AI tests read.
type aiCostBody struct {
	Scope string `json:"scope"`
	Total struct {
		USDMicros int64 `json:"usd_micros"`
	} `json:"total"`
	Parts []struct {
		Source          string `json:"source"`
		ProjectOrVendor string `json:"project_or_vendor"`
		Kind            string `json:"kind"`
		USDMicros       int64  `json:"usd_micros"`
	} `json:"parts"`
	Coverage []struct {
		Source string `json:"source"`
	} `json:"coverage"`
	AIShareFrom string `json:"ai_share_from"`
}

// aiCostsOf reads month as hum in tid: the shaped body and the raw answer.
func aiCostsOf(t *testing.T, r *wsLanesRig, tid, hum, month string) (aiCostBody, string) {
	t.Helper()
	code, body := call(t, r.e, tid, http.MethodGet, "/v1/tenant/costs?month="+month, hum, nil)
	raw, _ := json.Marshal(body)
	if code != http.StatusOK {
		t.Fatalf("costs in %s as %s: %d %s", tid, hum, code, raw)
	}
	var b aiCostBody
	if err := json.Unmarshal(raw, &b); err != nil {
		t.Fatal(err)
	}
	return b, string(raw)
}

// aiParts is b's parts of source, keyed vendor/kind.
func aiParts(b aiCostBody, source string) map[string]int64 {
	out := map[string]int64{}
	for _, p := range b.Parts {
		if p.Source == source {
			out[p.ProjectOrVendor+"/"+p.Kind] += p.USDMicros
		}
	}
	return out
}

// SPL-3810 (spec 143 costs-redesign 3.3.1, 5 row S3): one ended day, a claude
// item paying 10 USD for it, claude tokens w1 1000, w2 3000 and the
// operator's own 4000. A1 the estate (operator admin) reads the full
// 10000000 micros as ai_paid under its plan and no share; A2 w1 reads its
// share only, 1/8 = 1250000 micros (exact on Memory, the shared Postgres
// tables hold other tests' burn), no ai_paid, no plan, no w2; A3 w2 its 3/8;
// A4 the operator workspace's non-admin reads no AI part. RED CONTROLS:
// A2 fails when a workspace answer carries an ai_paid part, the plan or
// another workspace's share.
func TestCostReadAIPaidAndShare(t *testing.T) {
	r := newWSLanesRig(t)
	now := r.sameDay()
	m := now.Truncate(time.Minute).Add(-2 * time.Minute)
	day := m.Truncate(24 * time.Hour)
	_, onMemory := r.e.st.(*store.Memory)
	fp := r.e.st.(store.FleetPaidStore)
	plan := "plan-" + newTenantID("p")
	it, err := fp.CreatePaidItem(context.Background(), store.FleetPaidItem{Vendor: "claude", Kind: "subscription",
		PlanLabel: plan, Quantity: 1, Amount: 300, Currency: "USD", PeriodStart: day.Format(time.DateOnly),
		PeriodEnd: day.AddDate(0, 0, 30).Format(time.DateOnly), CreatedBy: "ai-test"})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = fp.DeletePaidItem(context.Background(), it.ID) })
	box := r.opBox.id
	laneAt(t, r.fleetTokensRig, "c-621", box, r.t1, "", now)
	laneAt(t, r.fleetTokensRig, "c-622", box, r.t2, "", now)
	laneAt(t, r.fleetTokensRig, "c-623", box, "", "", now)
	if _, err := r.push(t, r.opBox,
		tokSample{agent: "c-621", vendor: "claude", minute: m, in: 900, cw: 100, cr: 50000}, // cache reads out
		tokSample{agent: "c-622", vendor: "claude", minute: m, in: 3000},
		tokSample{agent: "c-623", vendor: "claude", minute: m, in: 4000}); err != nil {
		t.Fatal(err)
	}
	r.offset.Add(int64(24 * time.Hour)) // the day ended
	month := day.Format("2006-01")

	// A1
	est, _ := aiCostsOf(t, r, r.op, r.admin, month)
	if got := aiParts(est, store.CostSourceAIPaid)["claude/"+plan]; est.Scope != "estate" || got != 10_000_000 {
		t.Fatalf("A1 estate %s: ai_paid claude/%s = %d, want 10000000 (300 USD / 30 days, the full amount)", est.Scope, plan, got)
	}
	if n := len(aiParts(est, store.CostSourceAIShare)); n != 0 || est.AIShareFrom != "" {
		t.Fatalf("A1 the estate carries %d share parts (from %q): a share is never a second cost", n, est.AIShareFrom)
	}
	// A2, A3
	for _, c := range []struct {
		tid, hum, other string
		want            int64
	}{{r.w1, r.w1Admin, r.w2, 1_250_000}, {r.w2, r.w2Admin, r.w1, 3_750_000}} {
		b, raw := aiCostsOf(t, r, c.tid, c.hum, month)
		share := aiParts(b, store.CostSourceAIShare)
		if len(aiParts(b, store.CostSourceAIPaid)) != 0 || strings.Contains(raw, plan) || strings.Contains(raw, c.other) {
			t.Fatalf("A2 %s's answer carries an ai_paid part, the plan or %s: %s", c.tid, c.other, raw)
		}
		if len(share) != 1 || share["claude/share"] <= 0 || (onMemory && share["claude/share"] != c.want) {
			t.Fatalf("A2 %s ai_share %v, want claude/share = %d", c.tid, share, c.want)
		}
		if b.AIShareFrom != day.Format(time.DateOnly) && onMemory {
			t.Errorf("A2 %s ai_share_from %q, want %s", c.tid, b.AIShareFrom, day.Format(time.DateOnly))
		}
	}
	// A4
	b, _ := aiCostsOf(t, r, r.op, seat(t, r.e, r.op, rbac.Developer), month)
	if b.Scope != "workspace" || len(aiParts(b, store.CostSourceAIPaid))+len(aiParts(b, store.CostSourceAIShare)) != 0 {
		t.Fatalf("A4 the operator workspace's developer: scope %s, parts %+v, want no AI part", b.Scope, b.Parts)
	}
}

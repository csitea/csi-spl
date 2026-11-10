package hub_test

import (
	"net/http"
	"testing"
)

// SPL-5198 (owner HUM-10, t1 965283be msg 382450e2: "it must also have the
// pricess in dollars and euros"): the paid list answers each item in USD and
// EUR (store.PricePaidItems). A USD item is its own USD; with no EUR rate
// held (the Memory store keeps none) its EUR is null, never 0.
func TestFleetPaidListPriced(t *testing.T) {
	r := newFleetTokensRig(t)
	item := map[string]any{"vendor": "claude", "kind": "subscription", "plan_label": "priced fixture", "quantity": 2, "amount": 20, "currency": "USD",
		"period_start": "2003-11-01", "period_end": "2003-11-30"}
	code, got := call(t, r.e, r.op, http.MethodPost, fleetPaidPath, r.admin, item)
	id, _ := got["id"].(string)
	if code != http.StatusCreated || id == "" {
		t.Fatalf("create: %d %v", code, got)
	}
	t.Cleanup(func() { call(t, r.e, r.op, http.MethodDelete, fleetPaidPath+"/"+id, r.admin, nil) })
	code, got = call(t, r.e, r.op, http.MethodGet, fleetPaidPath, r.admin, nil)
	if code != http.StatusOK {
		t.Fatalf("list: %d %v", code, got)
	}
	for _, raw := range got["items"].([]any) {
		it := raw.(map[string]any)
		if it["id"] != id {
			continue
		}
		usd, hasUSD := it["usd_micros"]
		eur, hasEUR := it["eur_micros"]
		if !hasUSD || !hasEUR || usd != float64(20000000) || eur != nil {
			t.Errorf("item priced usd %v (%v) eur %v (%v), want 20000000 and null", usd, hasUSD, eur, hasEUR)
		}
		return
	}
	t.Fatalf("item %s not listed", id)
}

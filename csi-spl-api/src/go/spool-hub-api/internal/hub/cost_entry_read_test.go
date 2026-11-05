package hub_test

import (
	"encoding/json"
	"net/http"
	"testing"
)

// entryCostPart is the part of GET /v1/tenant/costs the entry test reads.
type entryCostPart struct {
	Source          string   `json:"source"`
	ProjectOrVendor string   `json:"project_or_vendor"`
	Kind            string   `json:"kind"`
	Origin          string   `json:"origin"`
	Hand            bool     `json:"hand"`
	USDMicros       int64    `json:"usd_micros"`
	SecondMicros    *int64   `json:"second_micros"`
	EntryMicros     int64    `json:"entry_micros"`
	EntryCurrency   string   `json:"entry_currency"`
	Unpriced        bool     `json:"unpriced"`
	Pct             *float64 `json:"pct"`
}

// entryMonth is the month answer the entry tests read.
type entryMonth struct {
	Total struct {
		USDMicros int64 `json:"usd_micros"`
	} `json:"total"`
	Parts []entryCostPart `json:"parts"`
	Human []entryCostPart `json:"human"`
}

// entryMonthRead is month's answer as hum in tid.
func entryMonthRead(t *testing.T, r *fleetTokensRig, tid, hum, month string) entryMonth {
	t.Helper()
	code, body := call(t, r.e, tid, http.MethodGet, "/v1/tenant/costs?month="+month, hum, nil)
	raw, _ := json.Marshal(body)
	if code != http.StatusOK {
		t.Fatalf("costs in %s as %s: %d %s", tid, hum, code, raw)
	}
	var b entryMonth
	if err := json.Unmarshal(raw, &b); err != nil {
		t.Fatal(err)
	}
	return b
}

// entryByLabel is the cost_entry part of parts labelled label.
func entryByLabel(parts []entryCostPart, label string) (entryCostPart, bool) {
	for _, p := range parts {
		if p.Source == "cost_entry" && p.ProjectOrVendor == label {
			return p, true
		}
	}
	return entryCostPart{}, false
}

// entryParts reads month as hum in tid: its cost_entry parts and Human rows
// labelled with one of labels (the shared Postgres table holds other tests'
// rows).
func entryParts(t *testing.T, r *fleetTokensRig, tid, hum, month string, labels ...string) map[string]entryCostPart {
	t.Helper()
	b := entryMonthRead(t, r, tid, hum, month)
	out := map[string]entryCostPart{}
	for _, l := range labels {
		if p, ok := entryByLabel(append(b.Parts, b.Human...), l); ok {
			out[l] = p
		}
	}
	return out
}

// SPL-4824 (owner csitea f7bba506 msg f987e4d5): the month answer of
// GET /v1/tenant/costs adds the month's cost entries as source cost_entry,
// the estate's only. E1 the operator admin reads a EUR cloud entry with its
// own amount and currency, origin hand, and its second currency (EUR, never
// picked) is the amount itself; a USD hr entry is its amount in USD. E2 an
// entry of another month is absent. E3 the operator workspace's developer
// and another workspace's admin read no entry. A EUR entry with no EUR rate
// says unpriced (Memory keeps no rates); one in XTS (the ISO test code, no
// rate anywhere) is unpriced with no USD and no second amount. RED CONTROL: E1 fails when the
// hub does not append the entries (cost_read.go `cm.Parts = append(cm.Parts,
// hand...)` removed).
func TestCostReadAddsCostEntries(t *testing.T) {
	r := newFleetTokensRig(t)
	month, other := "2003-07", "2003-08"
	cloud, hr, late := "ws cloud "+newTenantID("c"), "ws hr "+newTenantID("h"), "ws late "+newTenantID("l")
	norate := "ws norate " + newTenantID("n")
	for _, e := range []map[string]any{
		{"type": "cloud", "label": cloud, "amount": 64.8, "currency": "EUR", "period": month},
		{"type": "hr", "label": hr, "amount": 10, "currency": "USD", "period": month},
		{"type": "cloud", "label": late, "amount": 11.5, "currency": "EUR", "period": other},
		{"type": "cloud", "label": norate, "amount": 7, "currency": "XTS", "period": month},
	} {
		code, got := call(t, r.e, r.op, http.MethodPost, costEntryPath, r.admin, e)
		if code != http.StatusCreated {
			t.Fatalf("create %v: %d %v", e, code, got)
		}
		id, _ := got["id"].(string)
		t.Cleanup(func() { call(t, r.e, r.op, http.MethodDelete, costEntryPath+"/"+id, r.admin, nil) })
	}
	got := entryParts(t, r, r.op, r.admin, month, cloud, hr, late, norate)
	c, h, n := got[cloud], got[hr], got[norate]
	if c.Kind != "cloud" || c.Origin != "hand" || !c.Hand || c.EntryMicros != 64800000 || c.EntryCurrency != "EUR" ||
		c.SecondMicros == nil || *c.SecondMicros != 64800000 {
		t.Errorf("E1 cloud entry: %+v", c)
	}
	if c.Unpriced != (c.USDMicros == 0) {
		t.Errorf("E1 cloud entry: unpriced %v with usd %d", c.Unpriced, c.USDMicros)
	}
	if !n.Unpriced || n.USDMicros != 0 || n.SecondMicros != nil || n.EntryMicros != 7000000 || n.EntryCurrency != "XTS" {
		t.Errorf("E1 an entry in a currency with no rate is unpriced, no USD, no second: %+v", n)
	}
	if h.Kind != "hr" || h.USDMicros != 10000000 || h.Unpriced || h.EntryCurrency != "USD" {
		t.Errorf("E1 hr entry: %+v", h)
	}
	if _, ok := got[late]; ok {
		t.Errorf("E2 another month's entry is in %s: %+v", month, got[late])
	}
	for name, who := range map[string][2]string{"operator developer": {r.op, r.dev}, "other workspace admin": {r.other, r.otherA}} {
		if got := entryParts(t, r, who[0], who[1], month, cloud, hr); len(got) != 0 {
			t.Errorf("E3 %s reads the estate's entries: %+v", name, got)
		}
	}
}

// SPL-4840 (owner csitea f7bba506 poll d82c98e2, answer A "In Human; left
// out of Spend"): an hr entry is in the estate answer's human list, never
// in parts, so the USD total is the parts' sum without it (H1); a cloud
// entry stays in parts (H2). SPL-4824 R7 N1: an unpriced part (XTS, no
// rate anywhere) has no pct beside a total above 0 (H3). The operator
// workspace's developer reads no Human row (H4). RED CONTROL: on the master
// before SPL-4840 the hr entry is a part and there is no human list (H1
// fails), and the unpriced part reads pct 0 (H3 fails).
func TestCostReadHREntryInHumanNotSpend(t *testing.T) {
	r := newFleetTokensRig(t)
	month := "2003-10"
	hr, cloud, norate := "ws hr "+newTenantID("h"), "ws cloud "+newTenantID("c"), "ws norate "+newTenantID("n")
	for _, e := range []map[string]any{
		{"type": "hr", "label": hr, "amount": 30, "currency": "USD", "period": month},
		{"type": "cloud", "label": cloud, "amount": 20, "currency": "USD", "period": month},
		{"type": "cloud", "label": norate, "amount": 7, "currency": "XTS", "period": month},
	} {
		code, got := call(t, r.e, r.op, http.MethodPost, costEntryPath, r.admin, e)
		if code != http.StatusCreated {
			t.Fatalf("create %v: %d %v", e, code, got)
		}
		id, _ := got["id"].(string)
		t.Cleanup(func() { call(t, r.e, r.op, http.MethodDelete, costEntryPath+"/"+id, r.admin, nil) })
	}
	b := entryMonthRead(t, r, r.op, r.admin, month)
	if p, ok := entryByLabel(b.Parts, hr); ok {
		t.Errorf("H1 the hr entry is a Spend part: %+v", p)
	}
	h, ok := entryByLabel(b.Human, hr)
	if !ok || h.Kind != "hr" || !h.Hand || h.USDMicros != 30000000 || h.Pct != nil {
		t.Errorf("H1 the hr entry is not Human's row (hand, $30, no pct): %v %+v", ok, h)
	}
	var sum int64
	for _, p := range b.Parts {
		sum += p.USDMicros
	}
	if b.Total.USDMicros != sum {
		t.Errorf("H1 the USD total %d is not the parts' sum %d", b.Total.USDMicros, sum)
	}
	if c, ok := entryByLabel(b.Parts, cloud); !ok || c.USDMicros != 20000000 || c.Pct == nil {
		t.Errorf("H2 the cloud entry is not a Spend part with its share: %v %+v", ok, c)
	}
	if n, ok := entryByLabel(b.Parts, norate); !ok || !n.Unpriced || n.Pct != nil || b.Total.USDMicros <= 0 {
		t.Errorf("H3 the unpriced part carries a pct (total %d): %v %+v", b.Total.USDMicros, ok, n)
	}
	if d := entryMonthRead(t, r, r.op, r.dev, month); len(d.Human) != 0 {
		t.Errorf("H4 the operator developer reads Human rows: %+v", d.Human)
	}
}

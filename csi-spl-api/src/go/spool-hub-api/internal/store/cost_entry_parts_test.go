package store

import (
	"context"
	"testing"
)

// fakeEntryRates answers quote's rate from m (quote units per USD), the day
// asked as the rate's day.
func fakeEntryRates(m map[string]float64) CostEntryRate {
	return func(_ context.Context, quote, day string) (float64, string, bool, error) {
		r, ok := m[quote]
		return r, day, ok, nil
	}
}

// SPL-4824: a hand-entered cost's money. P1 a EUR entry of 64.80 at 0.9 EUR
// per USD is 72 USD, its EUR the amount, its second currency SEK the USD at
// 10 SEK per USD; P2 read in EUR, its second is the amount at rate 1; P3 a
// currency with no rate is unpriced: USD 0 and no second (never a guess), its
// own amount kept. RED CONTROL: P3 fails when Unpriced is not set
// (cost_entry_parts.go `p.Unpriced = true` removed).
func TestCostEntryParts(t *testing.T) {
	ctx := context.Background()
	rates := fakeEntryRates(map[string]float64{"EUR": 0.9, "SEK": 10})
	e := CostEntry{Type: "cloud", Label: "suite a", Amount: 64.8, Currency: "EUR", Period: "2026-01"}
	ps, err := CostEntryParts(ctx, []CostEntry{e}, "SEK", rates)
	if err != nil || len(ps) != 1 {
		t.Fatalf("P1: %v %v", ps, err)
	}
	p := ps[0]
	if p.Source != CostSourceEntry || !p.Estate || p.ProjectOrVendor != "suite a" || p.Kind != "cloud" || p.Origin != "hand" ||
		p.USDMicros != 72000000 || p.EURMicros != 64800000 || p.SecondMicros == nil || *p.SecondMicros != 720000000 ||
		p.EntryMicros != 64800000 || p.EntryCurrency != "EUR" || p.Unpriced || p.FXRate == nil || *p.FXRate != 10 {
		t.Errorf("P1: %+v", p)
	}
	ps, _ = CostEntryParts(ctx, []CostEntry{e}, "EUR", rates)
	if p := ps[0]; p.SecondMicros == nil || *p.SecondMicros != 64800000 || p.FXRate == nil || *p.FXRate != 1 ||
		p.FXRateDay == nil || *p.FXRateDay != "2026-01-01" {
		t.Errorf("P2: %+v", p)
	}
	e.Currency = "NOK"
	ps, _ = CostEntryParts(ctx, []CostEntry{e}, "SEK", rates)
	if p := ps[0]; !p.Unpriced || p.USDMicros != 0 || p.EURMicros != 0 || p.SecondMicros != nil || p.EntryMicros != 64800000 {
		t.Errorf("P3: %+v", p)
	}
}

// SPL-4824 on Postgres: the rates are FleetPaidFXRate's, so a month older
// than the rate history takes the first rate after it.
func TestCostEntryPartsPostgresRates(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	q := fxTestQuote(t, pg)
	if _, err := pg.PutFXRates(ctx, []FXRate{{Day: "2001-01-10", Quote: q, Rate: 2, Source: "ECB"}}); err != nil {
		t.Fatal(err)
	}
	ps, err := CostEntryParts(ctx, []CostEntry{{Type: "cloud", Label: "x", Amount: 10, Currency: q, Period: "2001-01"}}, "USD", pg.FleetPaidFXRate)
	if err != nil || len(ps) != 1 {
		t.Fatalf("%v %v", ps, err)
	}
	if p := ps[0]; p.USDMicros != 5000000 || p.Unpriced || p.SecondMicros == nil || *p.SecondMicros != 5000000 {
		t.Errorf("%+v", p)
	}
}

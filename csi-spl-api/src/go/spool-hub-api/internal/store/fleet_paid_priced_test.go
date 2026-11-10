package store

import (
	"context"
	"testing"
)

// SPL-5198: a paid item's USD and EUR at its period_start. P1 USD 10 at 0.9
// EUR per USD is EUR 9; P2 EUR 46 is USD 46/0.9, EUR the amount; P3 a
// currency with no rate is nil both (never 0); P4 SEK 105 at 10.5 is USD 10,
// EUR 9; the rate is asked for the period_start day.
// RED CONTROL: EURMicros from the USD when no EUR rate is held -> P5 fails.
func TestPricePaidItems(t *testing.T) {
	ctx := context.Background()
	var days []string
	base := fakeEntryRates(map[string]float64{"EUR": 0.9, "SEK": 10.5})
	rate := func(ctx context.Context, quote, day string) (float64, string, bool, error) {
		days = append(days, day)
		return base(ctx, quote, day)
	}
	items := []FleetPaidItem{
		{ID: "p1", Amount: 10, Currency: "USD", PeriodStart: "2026-09-03"},
		{ID: "p2", Amount: 46, Currency: "EUR", PeriodStart: "2026-09-03"},
		{ID: "p3", Amount: 7, Currency: "XTS", PeriodStart: "2026-09-03"},
		{ID: "p4", Amount: 105, Currency: "SEK", PeriodStart: "2026-10-15"},
	}
	ps, err := PricePaidItems(ctx, items, rate)
	if err != nil || len(ps) != 4 {
		t.Fatalf("priced: %v %v", ps, err)
	}
	want := []struct{ usd, eur *int64 }{
		{i64(10e6), i64(9e6)},
		{i64(51111111), i64(46e6)},
		{nil, nil},
		{i64(10e6), i64(9e6)},
	}
	for i, w := range want {
		if !sameI64(ps[i].USDMicros, w.usd) || !sameI64(ps[i].EURMicros, w.eur) {
			t.Errorf("P%d: usd %v eur %v, want %v %v", i+1, showMicros(ps[i].USDMicros), showMicros(ps[i].EURMicros), showMicros(w.usd), showMicros(w.eur))
		}
		if ps[i].ID != items[i].ID {
			t.Errorf("P%d: order %s", i+1, ps[i].ID)
		}
	}
	for _, d := range days {
		if d != "2026-09-03" && d != "2026-10-15" {
			t.Errorf("rate asked for %s, not a period_start", d)
		}
	}
	// P5: no EUR rate held: USD priced, EUR nil.
	ps, err = PricePaidItems(ctx, items[3:], fakeEntryRates(map[string]float64{"SEK": 10.5}))
	if err != nil || !sameI64(ps[0].USDMicros, i64(10e6)) || ps[0].EURMicros != nil {
		t.Errorf("P5: %v %v %v", showMicros(ps[0].USDMicros), showMicros(ps[0].EURMicros), err)
	}
}

// SPL-5198 R7 W2: each amount names the day of the rate that made it, not
// the day asked: R1 SEK on 2026-10-15 with the SEK rate from 2026-06-30 and
// the EUR rate from 2026-10-14 names 2026-06-30 for USD and the farther of
// the two, 2026-06-30, for EUR; R2 USD names no USD day and the EUR rate's
// for EUR; R3 EUR names the EUR rate's day for USD and none for EUR; R4 no rate
// names neither. The cost entries share the rule (priceUSDEUR): R5.
// RED CONTROL: EURDay = eur.day for every currency -> R1 fails.
func TestPricedRateDays(t *testing.T) {
	ctx := context.Background()
	at := map[string]string{"SEK": "2026-06-30", "EUR": "2026-10-14"}
	rate := func(_ context.Context, quote, _ string) (float64, string, bool, error) {
		r, ok := map[string]float64{"EUR": 0.9, "SEK": 10.5}[quote]
		return r, at[quote], ok, nil
	}
	items := []FleetPaidItem{
		{ID: "r1", Amount: 105, Currency: "SEK", PeriodStart: "2026-10-15"},
		{ID: "r2", Amount: 10, Currency: "USD", PeriodStart: "2026-10-15"},
		{ID: "r3", Amount: 9, Currency: "EUR", PeriodStart: "2026-10-15"},
		{ID: "r4", Amount: 7, Currency: "XTS", PeriodStart: "2026-10-15"},
	}
	ps, err := PricePaidItems(ctx, items, rate)
	if err != nil {
		t.Fatal(err)
	}
	day := func(p *string) string {
		if p == nil {
			return "-"
		}
		return *p
	}
	want := [][2]string{{"2026-06-30", "2026-06-30"}, {"-", "2026-10-14"}, {"2026-10-14", "-"}, {"-", "-"}}
	for i, w := range want {
		if g := [2]string{day(ps[i].USDRateDay), day(ps[i].EURRateDay)}; g != w {
			t.Errorf("R%d %s: rate days %v, want %v", i+1, items[i].Currency, g, w)
		}
	}
	ce, err := PriceCostEntries(ctx, []CostEntry{{ID: "e", Amount: 105, Currency: "SEK", Period: "2026-10"}}, rate)
	if err != nil || day(ce[0].USDRateDay) != "2026-06-30" || day(ce[0].EURRateDay) != "2026-06-30" {
		t.Errorf("R5: %s %s %v", day(ce[0].USDRateDay), day(ce[0].EURRateDay), err)
	}
}

func sameI64(a, b *int64) bool { return (a == nil) == (b == nil) && (a == nil || *a == *b) }

func showMicros(p *int64) any {
	if p == nil {
		return nil
	}
	return *p
}

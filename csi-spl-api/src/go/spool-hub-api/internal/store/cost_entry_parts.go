package store

import (
	"context"
	"math"
	"time"
)

// The month read's hand-entered costs (SPL-4824, spec 143; owner csitea
// f7bba506 msg f987e4d5: the Google Workspace invoices "should be added to
// the cloud costs of the costs tab in the reporting section"). Each
// cost_entries row (rdb 0245) of the month is its own part of source
// cost_entry: project_or_vendor its label, kind its type (cloud or hr),
// origin hand. The estate's only, like the rows themselves.
//
// Money: the entry's amount is in its own currency C. USD micros are that
// amount at C's rate of the month's first day (FleetPaidFXRate: that day,
// else the last before it, else the first after it), the paid items' rule;
// EUR micros are the amount when C is EUR, else the USD at the EUR rate;
// the second currency is the amount itself when it is C, else the USD at
// its rate. A rate the store does not hold is never guessed: USD 0 with
// Unpriced set (the row says so), and the amounts that need it nil or 0.

// CostSourceEntry is the month read's source of the cost_entries rows.
const CostSourceEntry = "cost_entry"

// CostEntryRate is FleetPaidFXRate's shape: quote units per USD on day.
type CostEntryRate func(ctx context.Context, quote, day string) (rate float64, rateDay string, ok bool, err error)

// costEntryFX is one looked-up rate; ok false = none.
type costEntryFX struct {
	rate float64
	day  string
	ok   bool
}

// CostEntryParts shapes entries (one month's) into parts in the order given,
// second the reader's second currency.
func CostEntryParts(ctx context.Context, entries []CostEntry, second string, rate CostEntryRate) ([]CostPart, error) {
	look := costEntryLook(ctx, rate)
	out := make([]CostPart, 0, len(entries))
	for _, e := range entries {
		p, err := costEntryPart(e, second, look)
		if err != nil {
			return nil, err
		}
		out = append(out, p)
	}
	return out, nil
}

// costEntryLook is rate with USD at 1 and each quote and day asked once.
func costEntryLook(ctx context.Context, rate CostEntryRate) func(quote, day string) (costEntryFX, error) {
	seen := map[[2]string]costEntryFX{}
	return func(quote, day string) (costEntryFX, error) {
		if quote == "USD" {
			return costEntryFX{rate: 1, day: day, ok: true}, nil
		}
		k := [2]string{quote, day}
		if fx, done := seen[k]; done {
			return fx, nil
		}
		r, at, ok, err := rate(ctx, quote, day)
		fx := costEntryFX{rate: r, day: at, ok: ok && err == nil && r > 0}
		seen[k] = fx
		return fx, err
	}
}

// costEntryPart is one entry's part.
func costEntryPart(e CostEntry, second string, look func(quote, day string) (costEntryFX, error)) (CostPart, error) {
	day := e.Period + "-01"
	amount := int64(math.Round(e.Amount * 1e6))
	p := CostPart{Estate: true, Source: CostSourceEntry, ProjectOrVendor: e.Label, Kind: e.Type, Origin: "hand",
		EntryMicros: amount, EntryCurrency: e.Currency}
	m, err := priceUSDEUR(amount, e.Currency, day, look)
	if err != nil {
		return p, err
	}
	if m.USD != nil {
		p.USDMicros = *m.USD
	} else {
		p.Unpriced = true
	}
	if m.EUR != nil {
		p.EURMicros = *m.EUR
	}
	if second == e.Currency {
		one := 1.0
		p.SecondMicros, p.FXRate, p.FXRateDay, p.FXRateFirstDay = &amount, &one, &day, &day
		return p, nil
	}
	sec, err := look(second, day)
	if err != nil || !m.own.ok || !sec.ok {
		return p, err
	}
	sm, r, at := int64(math.Round(m.usd*sec.rate)), sec.rate, sec.day
	p.SecondMicros, p.FXRate, p.FXRateDay, p.FXRateFirstDay = &sm, &r, &at, &at
	return p, nil
}

// usdEUR is an amount priced in USD and EUR (priceUSDEUR): micros, nil where
// no rate made it; each with the day of the rate that made it, nil where the
// amount is that currency (SPL-5198 R7 W2: the fallback rate may be from
// another day than asked, so the list names the day used).
type usdEUR struct {
	USD, EUR       *int64
	USDDay, EURDay *string
	usd            float64
	own            costEntryFX
}

// priceUSDEUR prices amount (micros, in currency) at day: USD at its own
// rate, EUR the amount when it is EUR, else the USD at the EUR rate, the day
// of the rate farther from day when two rates made it.
func priceUSDEUR(amount int64, currency, day string, look func(quote, day string) (costEntryFX, error)) (usdEUR, error) {
	var m usdEUR
	own, err := look(currency, day)
	if err != nil {
		return m, err
	}
	m.own = own
	if own.ok {
		m.usd = float64(amount) / own.rate
		u := int64(math.Round(m.usd))
		m.USD = &u
		if currency != "USD" {
			d := own.day
			m.USDDay = &d
		}
	}
	if currency == "EUR" {
		a := amount
		m.EUR = &a
		return m, nil
	}
	eur, err := look("EUR", day)
	if err != nil || !own.ok || !eur.ok {
		return m, err
	}
	e := int64(math.Round(m.usd * eur.rate))
	m.EUR = &e
	d := eur.day
	if currency != "USD" {
		d = fartherDay(day, own.day, eur.day)
	}
	m.EURDay = &d
	return m, nil
}

// fartherDay is whichever of a and b (YYYY-MM-DD) lies farther from day; a
// on a tie or an unreadable day.
func fartherDay(day, a, b string) string {
	gap := func(x string) float64 {
		t0, e0 := time.Parse(time.DateOnly, day)
		t1, e1 := time.Parse(time.DateOnly, x)
		if e0 != nil || e1 != nil {
			return -1
		}
		return math.Abs(t1.Sub(t0).Hours())
	}
	if gap(b) > gap(a) {
		return b
	}
	return a
}

// PricedCostEntry is a listed cost entry with its amount in USD and in EUR
// (SPL-5198; owner HUM-10, t1 965283be msg 382450e2: "it must also have the
// pricess in dollars and euros"), at the rates of its month as above; nil
// where no rate made it; each with the day of the rate used (usdEUR).
type PricedCostEntry struct {
	CostEntry
	USDMicros  *int64  `json:"usd_micros"`
	EURMicros  *int64  `json:"eur_micros"`
	USDRateDay *string `json:"usd_rate_day"`
	EURRateDay *string `json:"eur_rate_day"`
}

// PriceCostEntries prices entries in the order given at the first day of
// their month (priceUSDEUR).
func PriceCostEntries(ctx context.Context, entries []CostEntry, rate CostEntryRate) ([]PricedCostEntry, error) {
	look := costEntryLook(ctx, rate)
	out := make([]PricedCostEntry, 0, len(entries))
	for _, e := range entries {
		m, err := priceUSDEUR(int64(math.Round(e.Amount*1e6)), e.Currency, e.Period+"-01", look)
		if err != nil {
			return nil, err
		}
		out = append(out, PricedCostEntry{CostEntry: e, USDMicros: m.USD, EURMicros: m.EUR, USDRateDay: m.USDDay, EURRateDay: m.EURDay})
	}
	return out, nil
}

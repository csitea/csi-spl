package store

import (
	"context"
	"math"
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
	seen := map[[2]string]costEntryFX{}
	look := func(quote, day string) (costEntryFX, error) {
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

// costEntryPart is one entry's part.
func costEntryPart(e CostEntry, second string, look func(quote, day string) (costEntryFX, error)) (CostPart, error) {
	day := e.Period + "-01"
	amount := int64(math.Round(e.Amount * 1e6))
	p := CostPart{Estate: true, Source: CostSourceEntry, ProjectOrVendor: e.Label, Kind: e.Type, Origin: "hand",
		EntryMicros: amount, EntryCurrency: e.Currency}
	own, err := look(e.Currency, day)
	if err != nil {
		return p, err
	}
	var usd float64
	if own.ok {
		usd = float64(amount) / own.rate
		p.USDMicros = int64(math.Round(usd))
	} else {
		p.Unpriced = true
	}
	if e.Currency == "EUR" {
		p.EURMicros = amount
	} else if eur, err := look("EUR", day); err != nil {
		return p, err
	} else if own.ok && eur.ok {
		p.EURMicros = int64(math.Round(usd * eur.rate))
	}
	if second == e.Currency {
		one := 1.0
		p.SecondMicros, p.FXRate, p.FXRateDay, p.FXRateFirstDay = &amount, &one, &day, &day
		return p, nil
	}
	sec, err := look(second, day)
	if err != nil || !own.ok || !sec.ok {
		return p, err
	}
	sm, r, at := int64(math.Round(usd*sec.rate)), sec.rate, sec.day
	p.SecondMicros, p.FXRate, p.FXRateDay, p.FXRateFirstDay = &sm, &r, &at, &at
	return p, nil
}

// PricedCostEntry is a listed cost entry with its amount in USD and in EUR
// (SPL-5198; owner HUM-10, t1 965283be msg 382450e2: "it must also have the
// pricess in dollars and euros"), at the rates of its month as above; nil
// where no rate made it.
type PricedCostEntry struct {
	CostEntry
	USDMicros *int64 `json:"usd_micros"`
	EURMicros *int64 `json:"eur_micros"`
}

// PriceCostEntries prices entries in the order given: their parts read in
// EUR, so EUR is the second amount (nil with no rate) and USD the part's
// unless Unpriced.
func PriceCostEntries(ctx context.Context, entries []CostEntry, rate CostEntryRate) ([]PricedCostEntry, error) {
	parts, err := CostEntryParts(ctx, entries, "EUR", rate)
	if err != nil {
		return nil, err
	}
	out := make([]PricedCostEntry, 0, len(entries))
	for i, e := range entries {
		pe := PricedCostEntry{CostEntry: e, EURMicros: parts[i].SecondMicros}
		if !parts[i].Unpriced {
			usd := parts[i].USDMicros
			pe.USDMicros = &usd
		}
		out = append(out, pe)
	}
	return out, nil
}

package store

import (
	"context"
	"math"
)

// PricedPaidItem is a listed paid item with its amount in USD and in EUR
// (SPL-5198; owner HUM-10, t1 965283be msg 382450e2: "it must also have the
// pricess in dollars and euros"): the amount as entered, at the rates of its
// period_start, the day the effective read converts it at (FleetPaidFXRate);
// nil where no rate made it, never 0.
type PricedPaidItem struct {
	FleetPaidItem
	USDMicros *int64 `json:"usd_micros"`
	EURMicros *int64 `json:"eur_micros"`
}

// PricePaidItems prices items in the order given, the cost entries' rule
// (costEntryPart): USD at the item's own rate, EUR the amount when it is
// EUR, else the USD at the EUR rate.
func PricePaidItems(ctx context.Context, items []FleetPaidItem, rate CostEntryRate) ([]PricedPaidItem, error) {
	look := costEntryLook(ctx, rate)
	out := make([]PricedPaidItem, 0, len(items))
	for _, it := range items {
		p := PricedPaidItem{FleetPaidItem: it}
		amount := int64(math.Round(it.Amount * 1e6))
		own, err := look(it.Currency, it.PeriodStart)
		if err != nil {
			return nil, err
		}
		var usd float64
		if own.ok {
			usd = float64(amount) / own.rate
			u := int64(math.Round(usd))
			p.USDMicros = &u
		}
		if it.Currency == "EUR" {
			p.EURMicros = &amount
		} else if eur, err := look("EUR", it.PeriodStart); err != nil {
			return nil, err
		} else if own.ok && eur.ok {
			e := int64(math.Round(usd * eur.rate))
			p.EURMicros = &e
		}
		out = append(out, p)
	}
	return out, nil
}

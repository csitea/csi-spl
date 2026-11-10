package store

import (
	"context"
	"math"
)

// PricedPaidItem is a listed paid item with its amount in USD and in EUR
// (SPL-5198; owner HUM-10, t1 965283be msg 382450e2: "it must also have the
// pricess in dollars and euros"): the amount as entered, at the rates of its
// period_start, the day the effective read converts it at (FleetPaidFXRate);
// nil where no rate made it, never 0; each with the day of the rate used
// (usdEUR), which may not be period_start.
type PricedPaidItem struct {
	FleetPaidItem
	USDMicros  *int64  `json:"usd_micros"`
	EURMicros  *int64  `json:"eur_micros"`
	USDRateDay *string `json:"usd_rate_day"`
	EURRateDay *string `json:"eur_rate_day"`
}

// PricePaidItems prices items in the order given, the cost entries' rule
// (priceUSDEUR) at each item's period_start.
func PricePaidItems(ctx context.Context, items []FleetPaidItem, rate CostEntryRate) ([]PricedPaidItem, error) {
	look := costEntryLook(ctx, rate)
	out := make([]PricedPaidItem, 0, len(items))
	for _, it := range items {
		m, err := priceUSDEUR(int64(math.Round(it.Amount*1e6)), it.Currency, it.PeriodStart, look)
		if err != nil {
			return nil, err
		}
		out = append(out, PricedPaidItem{FleetPaidItem: it, USDMicros: m.USD, EURMicros: m.EUR, USDRateDay: m.USDDay, EURRateDay: m.EURDay})
	}
	return out, nil
}

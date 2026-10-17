package store

import (
	"context"
	"fmt"
	"math"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// What the operator PAID for the fleet's AI vendors (SPL-2342, rdb 0205
// fleet_token_paid_items; owner HUM-10, t1 e8ae0aad msg 9f549412: "I should
// report the paid subscriptions and you would calculate the price per
// token"). The operator enters each subscription or top-up; the hub spreads
// its total (amount * quantity) evenly over the UTC days it pays for,
// converts it to USD at the fx_rates rate of its first day (rdb 0200), and
// divides the days' shares by the tokens the vendor's lanes burned on them
// (rdb 0199: input + output + cache write; cache reads are counted and
// shown, never divided in). Operator scope only, like the token burn.

// FleetPaidKinds are rdb 0205's kind CHECK.
var FleetPaidKinds = []string{"subscription", "topup"}

// FleetPaidRangeMax is the longest effective-price read, in days (the daily
// rollups are kept 365 days).
const FleetPaidRangeMax = 366

// FleetPaidItem is one row of fleet_token_paid_items. The period is the UTC
// days [PeriodStart, PeriodEnd), both YYYY-MM-DD; Amount is one unit's price,
// so the item paid Amount * Quantity of Currency.
type FleetPaidItem struct {
	ID          string    `json:"id"`
	Vendor      string    `json:"vendor"`
	Kind        string    `json:"kind"`
	PlanLabel   string    `json:"plan_label"`
	Quantity    int       `json:"quantity"`
	Amount      float64   `json:"amount"`
	Currency    string    `json:"currency"`
	PeriodStart string    `json:"period_start"`
	PeriodEnd   string    `json:"period_end"`
	Note        string    `json:"note"`
	CreatedBy   string    `json:"created_by"`
	CreatedAt   time.Time `json:"created_at"`
	UpdatedAt   time.Time `json:"updated_at"`
}

// period is the item's first day and its day count; ok false = not a period.
func (it FleetPaidItem) period() (start time.Time, days int, ok bool) {
	s, err1 := time.Parse(time.DateOnly, it.PeriodStart)
	e, err2 := time.Parse(time.DateOnly, it.PeriodEnd)
	if err1 != nil || err2 != nil || s.Format(time.DateOnly) != it.PeriodStart || e.Format(time.DateOnly) != it.PeriodEnd {
		return time.Time{}, 0, false
	}
	return s, int(e.Sub(s) / (24 * time.Hour)), e.After(s)
}

// CheckFleetPaidItem names the first thing it may not carry ("" = fine): the
// Go side of rdb 0205's CHECKs. Whether the currency is one the hub holds a
// rate for is the route's check (it needs the store's fx_rates).
func CheckFleetPaidItem(it FleetPaidItem) string {
	_, _, ok := it.period()
	switch {
	case !slices.Contains(wire.FleetTokenVendors, it.Vendor):
		return "vendor must be one of " + strings.Join(wire.FleetTokenVendors, ", ")
	case !slices.Contains(FleetPaidKinds, it.Kind):
		return "kind must be subscription or topup"
	case strings.TrimSpace(it.PlanLabel) == "" || len(it.PlanLabel) > 100:
		return "plan_label must be 1..100 characters"
	case it.Quantity < 1 || it.Quantity > 1000:
		return "quantity must be 1..1000"
	case math.IsNaN(it.Amount) || math.IsInf(it.Amount, 0) || it.Amount <= 0 || it.Amount >= 1e10:
		return "amount must be a number above 0"
	case !IsCurrencyCode(it.Currency):
		return "currency must be an ISO 4217 code such as USD or EUR"
	case !ok:
		return "period_start and period_end must be UTC days YYYY-MM-DD, the end after the start"
	case len(it.Note) > 2000:
		return "note must be at most 2000 characters"
	}
	return ""
}

// FleetVendorDay is one vendor's burn on one UTC day: Tokens are input +
// output + cache write (what the paid amount is divided by), CacheRead the
// cache reads beside them, ListCostUSD the list-price cost (rdb 0199's
// cost_micros of the rows priced in USD) in USD.
type FleetVendorDay struct {
	Day         time.Time
	Vendor      string
	Tokens      int64
	CacheRead   int64
	ListCostUSD float64
}

// FleetPaidStore is the store half of rdb 0205. Optional: the routes answer
// unsupported on a store without it.
type FleetPaidStore interface {
	// ListPaidItems is every item, period_start then created_at order.
	ListPaidItems(ctx context.Context) ([]FleetPaidItem, error)
	// CreatePaidItem stores a checked item under a new id and answers it.
	CreatePaidItem(ctx context.Context, it FleetPaidItem) (FleetPaidItem, error)
	// UpdatePaidItem replaces item it.ID's fields but created_by and
	// created_at; ErrNotFound when there is none.
	UpdatePaidItem(ctx context.Context, it FleetPaidItem) (FleetPaidItem, error)
	// DeletePaidItem removes item id; ErrNotFound when there is none.
	DeletePaidItem(ctx context.Context, id string) error
	// FleetVendorDays is the burn per (UTC day, vendor) of the days
	// [from, to), metered rows only: a day still in the minute table is read
	// from it, an older one from the daily rollup.
	FleetVendorDays(ctx context.Context, from, to time.Time) ([]FleetVendorDay, error)
	// FleetPaidFXRate is quote units per USD on day, else the last rate
	// before it, else the first after it (a period older than the rate
	// history); ok false = the store holds no rate of quote.
	FleetPaidFXRate(ctx context.Context, quote, day string) (rate float64, rateDay string, ok bool, err error)
}

// FleetPaidShare is one item's part of an effective-price read.
type FleetPaidShare struct {
	ID        string   `json:"id"`
	Kind      string   `json:"kind"`
	PlanLabel string   `json:"plan_label"`
	Days      int      `json:"days"`
	PaidUSD   *float64 `json:"paid_usd"`
	FXRate    *float64 `json:"fx_rate"`
	FXRateDay *string  `json:"fx_rate_day"`
}

// FleetPaidVendor is one vendor's effective price over the read's days.
// Status: list_only (no paid item in the range: list price only), effective,
// not_metered (paid, but its lanes logged no tokens: agy), no_fx_rate (an
// item's currency has no rate, so no USD sum).
type FleetPaidVendor struct {
	Vendor              string           `json:"vendor"`
	Status              string           `json:"status"`
	Tokens              int64            `json:"tokens"`
	CacheRead           int64            `json:"cache_read"`
	ListCostUSD         float64          `json:"list_cost_usd"`
	ListUSDPerMTok      *float64         `json:"list_usd_per_mtok"`
	PaidUSD             *float64         `json:"paid_usd"`
	PaidPerDayUSD       *float64         `json:"paid_per_day_usd"`
	EffectiveUSDPerMTok *float64         `json:"effective_usd_per_mtok"`
	Items               []FleetPaidShare `json:"items"`
}

// FleetPaidEffectiveResponse is GET /v1/operator/fleet-tokens/effective.
type FleetPaidEffectiveResponse struct {
	From    string            `json:"from"`
	To      string            `json:"to"`
	Days    int               `json:"days"`
	Vendors []FleetPaidVendor `json:"vendors"`
}

// FleetPaidRate is an item's conversion: quote units per USD and the rate's
// day; ok false = none (a USD item needs none).
type FleetPaidRate func(it FleetPaidItem) (rate float64, day string, ok bool)

// fleetPaidDailyUSD is one item's share of one day, in USD. THE EXTENSION
// POINT for the owner's deferred "additional parameters" (msg 9f549412): a
// rule that weights an item's days (a usage cap, a discount, an unused
// remainder) changes this function and nothing else.
func fleetPaidDailyUSD(it FleetPaidItem, days int, rate float64) float64 {
	return it.Amount * float64(it.Quantity) / float64(days) / rate
}

// overlapDays is how many of the days [from, to) the item pays for.
func (it FleetPaidItem) overlapDays(from, to time.Time) int {
	s, days, ok := it.period()
	if !ok {
		return 0
	}
	e := s.Add(time.Duration(days) * 24 * time.Hour)
	if s.Before(from) {
		s = from
	}
	if e.After(to) {
		e = to
	}
	if !e.After(s) {
		return 0
	}
	return int(e.Sub(s) / (24 * time.Hour))
}

// fleetPaidShare is item it's share of [from, to); fxOK false = no rate.
func fleetPaidShare(it FleetPaidItem, from, to time.Time, rate FleetPaidRate) (FleetPaidShare, float64, bool) {
	_, days, _ := it.period()
	sh := FleetPaidShare{ID: it.ID, Kind: it.Kind, PlanLabel: it.PlanLabel, Days: it.overlapDays(from, to)}
	r := 1.0
	if it.Currency != "USD" {
		got, day, ok := rate(it)
		if !ok {
			return sh, 0, false
		}
		r = got
		sh.FXRate, sh.FXRateDay = &got, &day
	}
	usd := fleetPaidDailyUSD(it, days, r) * float64(sh.Days)
	rounded := cents(usd)
	sh.PaidUSD = &rounded
	return sh, usd, true
}

// FleetPaidEffective is the effective price of every vendor over the UTC days
// [from, to): items are every paid item (those outside the range add
// nothing), days the vendors' burn on those days (FleetVendorDays), rate the
// non-USD items' conversion. Pure: both drivers' data, one math.
func FleetPaidEffective(items []FleetPaidItem, days []FleetVendorDay, from, to time.Time, rate FleetPaidRate) FleetPaidEffectiveResponse {
	n := int(to.Sub(from) / (24 * time.Hour))
	out := FleetPaidEffectiveResponse{From: from.Format(time.DateOnly), To: to.Format(time.DateOnly), Days: n, Vendors: []FleetPaidVendor{}}
	for _, v := range wire.FleetTokenVendors {
		row := fleetPaidBurn(v, days, from, to)
		fleetPaidAddItems(&row, items, from, to, n, rate)
		out.Vendors = append(out.Vendors, row)
	}
	return out
}

// fleetPaidBurn is vendor v's row with its burn and list price over [from, to).
func fleetPaidBurn(v string, days []FleetVendorDay, from, to time.Time) FleetPaidVendor {
	row := FleetPaidVendor{Vendor: v, Status: "list_only", Items: []FleetPaidShare{}}
	for _, d := range days {
		if d.Vendor == v && !d.Day.Before(from) && d.Day.Before(to) {
			row.Tokens, row.CacheRead, row.ListCostUSD = row.Tokens+d.Tokens, row.CacheRead+d.CacheRead, row.ListCostUSD+d.ListCostUSD
		}
	}
	if row.Tokens > 0 {
		per := cents(row.ListCostUSD / float64(row.Tokens) * 1e6)
		row.ListUSDPerMTok = &per
	}
	row.ListCostUSD = cents(row.ListCostUSD)
	return row
}

// fleetPaidAddItems adds row's vendor's items paying for a day of [from, to)
// (n days): their USD shares, the daily share and the effective price.
func fleetPaidAddItems(row *FleetPaidVendor, items []FleetPaidItem, from, to time.Time, n int, rate FleetPaidRate) {
	var paid float64
	fxOK := true
	for _, it := range items {
		if it.Vendor != row.Vendor || it.overlapDays(from, to) == 0 {
			continue
		}
		sh, usd, ok := fleetPaidShare(it, from, to, rate)
		row.Items = append(row.Items, sh)
		paid, fxOK = paid+usd, fxOK && ok
	}
	switch {
	case len(row.Items) == 0:
		return
	case !fxOK:
		row.Status = "no_fx_rate"
		return
	}
	total, perDay := cents(paid), cents(paid/float64(n))
	row.PaidUSD, row.PaidPerDayUSD = &total, &perDay
	if row.Tokens == 0 {
		row.Status = "not_metered"
		return
	}
	eff := cents(paid / float64(row.Tokens) * 1e6)
	row.Status, row.EffectiveUSDPerMTok = "effective", &eff
}

// cents is a USD sum to the 1/10000 (a per-token price needs more than cents).
func cents(v float64) float64 { return math.Round(v*1e4) / 1e4 }

// FleetPaidWindow is the read's days: from and to (YYYY-MM-DD, to excluded)
// as given, else the last 30 whole UTC days before now's day (a missing from
// is 30 days before to). A non-empty third value says why the query is
// refused.
func FleetPaidWindow(from, to string, now time.Time) (time.Time, time.Time, string) {
	today := now.UTC().Truncate(24 * time.Hour)
	f, t := today.Add(-30*24*time.Hour), today
	var err error
	if to != "" {
		if t, err = time.Parse(time.DateOnly, to); err != nil {
			return f, t, "to must be a UTC day YYYY-MM-DD"
		}
		f = t.Add(-30 * 24 * time.Hour)
	}
	if from != "" {
		if f, err = time.Parse(time.DateOnly, from); err != nil {
			return f, t, "from must be a UTC day YYYY-MM-DD"
		}
	}
	if n := int(t.Sub(f) / (24 * time.Hour)); n < 1 || n > FleetPaidRangeMax {
		return f, t, fmt.Sprintf("to must be 1..%d days after from", FleetPaidRangeMax)
	}
	return f, t, ""
}

// The Memory driver keeps its rows beside the store, like the token burn.
var (
	memFleetPaidMu sync.Mutex
	memFleetPaid   = map[*Memory]map[string]FleetPaidItem{}
)

// ListPaidItems is FleetPaidStore on Memory.
func (s *Memory) ListPaidItems(_ context.Context) ([]FleetPaidItem, error) {
	memFleetPaidMu.Lock()
	defer memFleetPaidMu.Unlock()
	out := []FleetPaidItem{}
	for _, it := range memFleetPaid[s] {
		out = append(out, it)
	}
	sortFleetPaid(out)
	return out, nil
}

func sortFleetPaid(out []FleetPaidItem) {
	sort.Slice(out, func(i, j int) bool {
		if out[i].PeriodStart != out[j].PeriodStart {
			return out[i].PeriodStart < out[j].PeriodStart
		}
		if !out[i].CreatedAt.Equal(out[j].CreatedAt) {
			return out[i].CreatedAt.Before(out[j].CreatedAt)
		}
		return out[i].ID < out[j].ID
	})
}

// CreatePaidItem is FleetPaidStore on Memory.
func (s *Memory) CreatePaidItem(_ context.Context, it FleetPaidItem) (FleetPaidItem, error) {
	if why := CheckFleetPaidItem(it); why != "" {
		return FleetPaidItem{}, fmt.Errorf("fleet paid item: %s", why)
	}
	memFleetPaidMu.Lock()
	defer memFleetPaidMu.Unlock()
	if memFleetPaid[s] == nil {
		memFleetPaid[s] = map[string]FleetPaidItem{}
	}
	now := time.Now().UTC().Truncate(time.Microsecond)
	it.ID, it.CreatedAt, it.UpdatedAt = uuid.New(), now, now
	memFleetPaid[s][it.ID] = it
	return it, nil
}

// UpdatePaidItem is FleetPaidStore on Memory.
func (s *Memory) UpdatePaidItem(_ context.Context, it FleetPaidItem) (FleetPaidItem, error) {
	if why := CheckFleetPaidItem(it); why != "" {
		return FleetPaidItem{}, fmt.Errorf("fleet paid item: %s", why)
	}
	memFleetPaidMu.Lock()
	defer memFleetPaidMu.Unlock()
	old, ok := memFleetPaid[s][it.ID]
	if !ok {
		return FleetPaidItem{}, ErrNotFound
	}
	it.CreatedBy, it.CreatedAt, it.UpdatedAt = old.CreatedBy, old.CreatedAt, time.Now().UTC().Truncate(time.Microsecond)
	memFleetPaid[s][it.ID] = it
	return it, nil
}

// DeletePaidItem is FleetPaidStore on Memory.
func (s *Memory) DeletePaidItem(_ context.Context, id string) error {
	memFleetPaidMu.Lock()
	defer memFleetPaidMu.Unlock()
	if _, ok := memFleetPaid[s][id]; !ok {
		return ErrNotFound
	}
	delete(memFleetPaid[s], id)
	return nil
}

// FleetVendorDays is FleetPaidStore on Memory: the same precedence as
// Postgres (a day with minute rows is read from them).
func (s *Memory) FleetVendorDays(_ context.Context, from, to time.Time) ([]FleetVendorDay, error) {
	memFleetTokensMu.Lock()
	defer memFleetTokensMu.Unlock()
	acc, minuteDays := map[[2]string]*FleetVendorDay{}, map[string]bool{}
	add := func(day time.Time, vendor string, tin, tout, cr, cw int64, cost float64, usd bool) {
		k := [2]string{day.Format(time.DateOnly), vendor}
		d := acc[k]
		if d == nil {
			d = &FleetVendorDay{Day: day, Vendor: vendor}
			acc[k] = d
		}
		d.Tokens, d.CacheRead = d.Tokens+tin+tout+cw, d.CacheRead+cr
		if usd {
			d.ListCostUSD += cost / 1e6
		}
	}
	for _, b := range memFleetTokens[s] {
		if day := b.Minute.Truncate(24 * time.Hour); b.IsMetered && !day.Before(from) && day.Before(to) {
			minuteDays[day.Format(time.DateOnly)] = true
			add(day, b.Vendor, b.TokensIn, b.TokensOut, b.CacheRead, b.CacheWrite, b.CostMicros, b.Priced && b.Currency == "USD")
		}
	}
	for _, d := range memFleetDays[s] {
		if d.IsMetered && !d.Day.Before(from) && d.Day.Before(to) && !minuteDays[d.Day.Format(time.DateOnly)] {
			add(d.Day, d.Vendor, d.TokensIn, d.TokensOut, d.CacheRead, d.CacheWrite, d.CostMicros, d.Currency == "USD")
		}
	}
	out := make([]FleetVendorDay, 0, len(acc))
	for _, d := range acc {
		out = append(out, *d)
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].Day.Equal(out[j].Day) {
			return out[i].Day.Before(out[j].Day)
		}
		return out[i].Vendor < out[j].Vendor
	})
	return out, nil
}

// FleetPaidFXRate is FleetPaidStore on Memory: it keeps no exchange rates.
func (s *Memory) FleetPaidFXRate(context.Context, string, string) (float64, string, bool, error) {
	return 0, "", false, nil
}

var _ FleetPaidStore = (*Memory)(nil)

package store

import (
	"context"
	"fmt"
	"math"
	"math/big"
	"sort"
	"time"
)

// The month read's AI parts (spec 143 costs-redesign.md sections 3.3.1, 4
// and 5 row S3, SPL-3810; owner HUM-10, t1 1be0e370 poll 17403643 msg
// 3f1c7128, answer 4 B: "Also a share of the AI subscriptions, split by its
// lanes' tokens"). Every paid item (rdb 0205) pays one daily USD amount
// (fleetPaidDailyUSD) for each UTC day of its period; this read counts the
// ended days of a month:
//
//   - the ESTATE (the operator workspace's admin) gets source ai_paid, one
//     part per (agent type, plan): the items' full daily amounts;
//   - a CUSTOMER workspace W gets source ai_share, one part per agent type
//     (no plan, price or item): per item and day
//     floor(daily micros * T(W) / T(all)), T = the agent type's metered
//     input + output + cache-write tokens of that day, T(all) counting the
//     NULL work_tenant (the operator's own) tokens too. A day with no tokens
//     of the type, or an item with no FX rate, gives no share; the remainder
//     stays with the estate, whose total never changes by a share.
//
// The operator workspace's own members (not its admin) get neither: the
// hub never asks for them (3.3.1 point 4), and the store refuses it.

// AI part sources of the month read.
const (
	CostSourceAIPaid  = "ai_paid"
	CostSourceAIShare = "ai_share"
)

// AIPaidQuery is one month's ended days [From, CoverTo) of the estate
// (Workspace "") or of one customer workspace. Operator names the operator
// workspace (refused as Workspace). Currency is the second currency.
type AIPaidQuery struct {
	Operator  string
	Workspace string
	From      string
	CoverTo   string
	Currency  string
}

// AIPaidMonth is what AIPaidRead answers: the parts, the source's coverage
// (a day is read when every item paying for it has a rate) and, for a
// workspace, ShareFrom: the first day of the read holding any token stamped
// with a workspace ("" = none: no share can exist before it, 3.3.1).
type AIPaidMonth struct {
	Parts     []CostPart
	Coverage  CostSourceDays
	ShareFrom string
}

// AIPaidRead is the store half. Optional: the month read adds no AI part on
// a store without it.
type AIPaidRead interface {
	AIPaidMonthRead(ctx context.Context, q AIPaidQuery) (AIPaidMonth, error)
}

// WorkspaceBurnDay is the metered input + output + cache-write tokens of one
// (UTC day, agent type, work_tenant); Workspace "" = NULL (the operator's own).
type WorkspaceBurnDay struct {
	Day       string
	Vendor    string
	Workspace string
	Tokens    int64
}

// fxDay is the rate a cost day converts at, and that rate's own day.
type fxDay struct {
	rate float64
	day  string
}

// aiPaidSource is what both drivers read for AIPaidMonthRead.
type aiPaidSource interface {
	ListPaidItems(ctx context.Context) ([]FleetPaidItem, error)
	FleetPaidFXRate(ctx context.Context, quote, day string) (float64, string, bool, error)
	// WorkspaceBurnDays is the burn of [from, to) per (day, agent type,
	// work_tenant), each day once: from the minutes while it has any, else
	// from the daily rollup.
	WorkspaceBurnDays(ctx context.Context, from, to time.Time) ([]WorkspaceBurnDay, error)
	// secondFXDays is quote's rate of every day of [from, to): that day's,
	// else the last before it; a day with none is absent.
	secondFXDays(ctx context.Context, quote string, from, to time.Time) (map[string]fxDay, error)
}

var (
	_ AIPaidRead = (*Postgres)(nil)
	_ AIPaidRead = (*Memory)(nil)
)

// checkAIPaidQuery names the first thing q may not carry ("" = fine).
func checkAIPaidQuery(q AIPaidQuery) (from, to time.Time, why string) {
	from, err1 := time.Parse(time.DateOnly, q.From)
	to, err2 := time.Parse(time.DateOnly, q.CoverTo)
	switch {
	case !workTenantRe.MatchString(q.Operator):
		return from, to, "the operator workspace is required"
	case q.Workspace != "" && !workTenantRe.MatchString(q.Workspace):
		return from, to, "workspace must be a workspace id"
	case q.Workspace == q.Operator:
		return from, to, "the operator workspace's members get no share"
	case err1 != nil || err2 != nil || to.Before(from):
		return from, to, "from and cover_to must be UTC days YYYY-MM-DD, from not after cover_to"
	case to.Sub(from) > 31*24*time.Hour:
		return from, to, "at most one month"
	case q.Currency != "" && !IsCurrencyCode(q.Currency):
		return from, to, "currency must be an ISO 4217 code"
	}
	return from, to, ""
}

// AIPaidMonthRead is AIPaidRead on Postgres (see the file comment).
func (s *Postgres) AIPaidMonthRead(ctx context.Context, q AIPaidQuery) (AIPaidMonth, error) {
	return aiPaidMonthRead(ctx, s, q)
}

// AIPaidMonthRead is AIPaidRead on Memory (no FX rates: USD items only).
func (s *Memory) AIPaidMonthRead(ctx context.Context, q AIPaidQuery) (AIPaidMonth, error) {
	return aiPaidMonthRead(ctx, s, q)
}

// aiPaidMonthRead reads q's items, their rates, the second currency's days
// and (a workspace) the burn, then shapes them: one math for both drivers.
func aiPaidMonthRead(ctx context.Context, src aiPaidSource, q AIPaidQuery) (AIPaidMonth, error) {
	from, to, why := checkAIPaidQuery(q)
	if why != "" {
		return AIPaidMonth{}, fmt.Errorf("ai paid month: %s", why)
	}
	items, err := src.ListPaidItems(ctx)
	if err != nil {
		return AIPaidMonth{}, err
	}
	rates, err := aiPaidRates(ctx, src, items)
	if err != nil {
		return AIPaidMonth{}, err
	}
	cur := q.Currency
	if cur == "" {
		cur = DefaultSecondCurrency
	}
	second, err := src.secondFXDays(ctx, cur, from, to)
	if err != nil {
		return AIPaidMonth{}, err
	}
	days, unpriced := aiPaidItemDays(items, rates, from, to)
	if q.Workspace == "" {
		return AIPaidMonth{Parts: aiPaidParts(days, second),
			Coverage: aiPaidCoverage(CostSourceAIPaid, from, to, unpriced)}, nil
	}
	burn, err := src.WorkspaceBurnDays(ctx, from, to)
	if err != nil {
		return AIPaidMonth{}, err
	}
	return AIPaidMonth{Parts: aiShareParts(days, burn, q.Workspace, second),
		Coverage: aiPaidCoverage(CostSourceAIShare, from, to, unpriced), ShareFrom: aiShareFrom(burn)}, nil
}

// aiPaidRates looks every non-USD item's rate up once per (currency, first
// day): the effective price's rule (FleetPaidFXRate); rate 0 = none.
func aiPaidRates(ctx context.Context, src aiPaidSource, items []FleetPaidItem) (map[[2]string]fxDay, error) {
	out := map[[2]string]fxDay{}
	for _, it := range items {
		k := [2]string{it.Currency, it.PeriodStart}
		if _, done := out[k]; done || it.Currency == "USD" {
			continue
		}
		r, day, ok, err := src.FleetPaidFXRate(ctx, it.Currency, it.PeriodStart)
		if err != nil {
			return nil, err
		}
		if !ok {
			r = 0 // no rate: no USD amount (3.3.1 point 4)
		}
		out[k] = fxDay{rate: r, day: day}
	}
	return out, nil
}

// aiPaidDay is one item's daily amount on one ended day.
type aiPaidDay struct {
	Day    string
	Vendor string
	Plan   string
	Micros int64
}

// AIPaidDailyMicros is item it's USD micros of each day it pays for at rate
// (quote units per USD; 1 for USD): round(fleetPaidDailyUSD * 1e6), the
// amount both the estate and the shares count.
func AIPaidDailyMicros(it FleetPaidItem, rate float64) int64 {
	_, days, ok := it.period()
	if !ok || rate <= 0 {
		return 0
	}
	return int64(math.Round(fleetPaidDailyUSD(it, days, rate) * 1e6))
}

// aiPaidItemDays is every item's amount on each day of [from, to) it pays
// for, and the days an item with no rate pays for (not read).
func aiPaidItemDays(items []FleetPaidItem, rates map[[2]string]fxDay, from, to time.Time) ([]aiPaidDay, map[string]bool) {
	out, unpriced := []aiPaidDay{}, map[string]bool{}
	for _, it := range items {
		start, n, ok := it.period()
		if !ok || it.overlapDays(from, to) == 0 {
			continue
		}
		r := 1.0
		if it.Currency != "USD" {
			r = rates[[2]string{it.Currency, it.PeriodStart}].rate
		}
		micros := AIPaidDailyMicros(it, r)
		for i := 0; i < n; i++ {
			d := start.AddDate(0, 0, i)
			if d.Before(from) || !d.Before(to) {
				continue
			}
			if r <= 0 {
				unpriced[d.Format(time.DateOnly)] = true
				continue
			}
			out = append(out, aiPaidDay{Day: d.Format(time.DateOnly), Vendor: it.Vendor, Plan: it.PlanLabel, Micros: micros})
		}
	}
	return out, unpriced
}

// AIShareSplit splits one item's daily micros over the workspaces by their
// tokens of its agent type that day (tokens: workspace -> T, "" = the NULL
// rows, kept in the denominator): floor(micros * T(W) / T(all)) per
// workspace W != "". No token of the type: no share. The shares never sum
// above micros; the remainder and the NULL rows' part stay with the estate.
func AIShareSplit(micros int64, tokens map[string]int64) map[string]int64 {
	out, all := map[string]int64{}, new(big.Int)
	for _, t := range tokens {
		if t > 0 {
			all.Add(all, big.NewInt(t))
		}
	}
	if all.Sign() == 0 || micros <= 0 {
		return out
	}
	for ws, t := range tokens {
		if ws == "" || t <= 0 {
			continue
		}
		// micros x T can pass int64; T <= all, so the quotient fits.
		q := new(big.Int).Mul(big.NewInt(micros), big.NewInt(t))
		out[ws] = q.Quo(q, all).Int64()
	}
	return out
}

// aiPaidParts is the estate's parts: per (agent type, plan) the items'
// daily amounts, by day.
func aiPaidParts(days []aiPaidDay, second map[string]fxDay) []CostPart {
	by := map[[2]string]map[string]int64{}
	for _, d := range days {
		k := [2]string{d.Vendor, d.Plan}
		if by[k] == nil {
			by[k] = map[string]int64{}
		}
		by[k][d.Day] += d.Micros
	}
	out := []CostPart{}
	for k, perDay := range by {
		out = append(out, aiCostPart(CostPart{Estate: true, Source: CostSourceAIPaid, ProjectOrVendor: k[0], Kind: k[1],
			Origin: "paid_item"}, perDay, second))
	}
	sortAIParts(out)
	return out
}

// aiShareParts is workspace ws's parts: per agent type the sum of its daily
// shares of every item (3.3.1 point 3: never recomputed from totals).
func aiShareParts(days []aiPaidDay, burn []WorkspaceBurnDay, ws string, second map[string]fxDay) []CostPart {
	tokens := map[[2]string]map[string]int64{} // (day, vendor) -> workspace -> T
	for _, b := range burn {
		k := [2]string{b.Day, b.Vendor}
		if tokens[k] == nil {
			tokens[k] = map[string]int64{}
		}
		tokens[k][b.Workspace] += b.Tokens
	}
	by := map[string]map[string]int64{}
	for _, d := range days {
		share := AIShareSplit(d.Micros, tokens[[2]string{d.Day, d.Vendor}])[ws]
		if share <= 0 {
			continue
		}
		if by[d.Vendor] == nil {
			by[d.Vendor] = map[string]int64{}
		}
		by[d.Vendor][d.Day] += share
	}
	out := []CostPart{}
	for v, perDay := range by {
		out = append(out, aiCostPart(CostPart{Source: CostSourceAIShare, ProjectOrVendor: v, Kind: "share",
			Origin: "paid_item"}, perDay, second))
	}
	sortAIParts(out)
	return out
}

// aiCostPart fills p's money from its USD micros per day: second_micros is
// each day at that day's rate (else the last before it), all nil when a day
// has none (the cost lines' rule, cost_read.go). EUR micros stay 0: the
// fixed EUR column is gone (costs-redesign 4), the second currency carries it.
func aiCostPart(p CostPart, perDay map[string]int64, second map[string]fxDay) CostPart {
	var sum float64
	first, last, complete := "", "", true
	for day, m := range perDay {
		p.USDMicros += m
		p.Days++
		fx, ok := second[day]
		complete = complete && ok
		sum += float64(m) * fx.rate
		if first == "" || day < first {
			first = day
		}
		if day > last {
			last = day
		}
	}
	if complete && p.Days > 0 {
		sm := int64(math.Round(sum))
		rate, lastDay, firstDay := second[last].rate, second[last].day, second[first].day
		p.SecondMicros, p.FXRate, p.FXRateDay, p.FXRateFirstDay = &sm, &rate, &lastDay, &firstDay
	}
	return p
}

func sortAIParts(ps []CostPart) {
	sort.Slice(ps, func(i, j int) bool {
		if ps[i].ProjectOrVendor != ps[j].ProjectOrVendor {
			return ps[i].ProjectOrVendor < ps[j].ProjectOrVendor
		}
		return ps[i].Kind < ps[j].Kind
	})
}

// aiPaidCoverage is source's days of [from, to): ok, or missing when an item
// paying for the day has no rate.
func aiPaidCoverage(source string, from, to time.Time, unpriced map[string]bool) CostSourceDays {
	c := CostSourceDays{Source: source}
	for d := from; d.Before(to); d = d.AddDate(0, 0, 1) {
		if unpriced[d.Format(time.DateOnly)] {
			c.Missing++
		} else {
			c.OK++
		}
	}
	return c
}

// aiShareFrom is the first day of burn holding a workspace-stamped token.
func aiShareFrom(burn []WorkspaceBurnDay) string {
	first := ""
	for _, b := range burn {
		if b.Workspace != "" && b.Tokens > 0 && (first == "" || b.Day < first) {
			first = b.Day
		}
	}
	return first
}

// WorkspaceBurnDays is aiPaidSource on Memory: the minutes of a day that has
// any, else its rollup (FleetVendorDays' precedence).
func (s *Memory) WorkspaceBurnDays(_ context.Context, from, to time.Time) ([]WorkspaceBurnDay, error) {
	memFleetTokensMu.Lock()
	defer memFleetTokensMu.Unlock()
	acc, minuteDays := map[[3]string]int64{}, map[string]bool{}
	for _, b := range memFleetTokens[s] {
		if day := b.Minute.Truncate(24 * time.Hour); b.IsMetered && !day.Before(from) && day.Before(to) {
			minuteDays[day.Format(time.DateOnly)] = true
			acc[[3]string{day.Format(time.DateOnly), b.Vendor, b.WorkTenant}] += b.TokensIn + b.TokensOut + b.CacheWrite
		}
	}
	for _, d := range memFleetDays[s] {
		if day := d.Day.Format(time.DateOnly); d.IsMetered && !d.Day.Before(from) && d.Day.Before(to) && !minuteDays[day] {
			acc[[3]string{day, d.Vendor, d.WorkTenant}] += d.TokensIn + d.TokensOut + d.CacheWrite
		}
	}
	out := make([]WorkspaceBurnDay, 0, len(acc))
	for k, n := range acc {
		out = append(out, WorkspaceBurnDay{Day: k[0], Vendor: k[1], Workspace: k[2], Tokens: n})
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		return a.Day+a.Vendor+"\x00"+a.Workspace < b.Day+b.Vendor+"\x00"+b.Workspace
	})
	return out, nil
}

// secondFXDays is aiPaidSource on Memory: it keeps no exchange rates.
func (s *Memory) secondFXDays(context.Context, string, time.Time, time.Time) (map[string]fxDay, error) {
	return map[string]fxDay{}, nil
}

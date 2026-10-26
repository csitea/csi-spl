package store

import (
	"context"
	"math"
	"math/big"
	"sort"
	"strings"
	"sync"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Live token burn of the fleet's agent lanes (spec 140 section 3, rdb 0199).
// A box pushes one row per (agent_id, UTC minute); the hub writes it under
// the box key of the session (box_tag), priced at write time against the
// model_prices row in force at the minute (rdb 0171, the same rows usage
// metering reads), so a later price change never re-prices history. A
// re-sent minute overwrites its row. Operator scope only: these are the
// instance's estate rows, no tenant. They are not spec 123's daily cost_lines
// and are never summed with them.
//
// The hub's retention sweep (PruneOldBuckets) rolls whole UTC days into
// fleet_token_burn_daily, then drops minutes older than
// FleetTokensRetention and days older than FleetTokensDailyRetention.

// Retention (spec 140 3.6, owner decision 2 = B).
const (
	FleetTokensRetention      = 30 * 24 * time.Hour
	FleetTokensDailyRetention = 365 * 24 * time.Hour
	// FleetTokenRowsMax is the most minute rows one read returns: 40 lanes
	// times 24 h is 57.6k, so a 24 h window of a busy fleet fits twice.
	FleetTokenRowsMax = 150000
)

// fleetTokenProviders maps an agent kind to its model_prices provider.
var fleetTokenProviders = map[string]string{"claude": "anthropic", "mistral": "mistral", "grok": "xai", "agy": "google", "qwen": "qwen"}

// FleetTokenProvider is the model_prices provider of an agent kind ("" = none).
func FleetTokenProvider(vendor string) string { return fleetTokenProviders[vendor] }

// fleetTokenModel is the model_prices model of a transcript's model name: a
// context-size suffix such as "[1m]" and a snapshot date such as
// "-20251001" (claude-haiku-4-5-20251001 is claude-haiku-4-5) name no other
// price row.
func fleetTokenModel(m string) string {
	if i := strings.IndexByte(m, '['); i > 0 && strings.HasSuffix(m, "]") {
		m = m[:i]
	}
	if n := len(m) - 9; n > 0 && m[n] == '-' && strings.Trim(m[n+1:], "0123456789") == "" {
		m = m[:n]
	}
	return m
}

// FleetTokenBucket is one row of fleet_token_burn_events. CostMicros is the
// row's cost in micros of Currency; Priced is false when a counted kind had
// no price in force (CostMicros is then 0).
type FleetTokenBucket struct {
	BoxTag     string
	AgentID    string
	Vendor     string
	Model      string
	Minute     time.Time
	TokensIn   int64
	TokensOut  int64
	CacheRead  int64
	CacheWrite int64
	CostMicros float64
	Currency   string
	Priced     bool
	IsMetered  bool
	WorkTenant string // the workspace the lane worked for, "" = the operator's own (rdb 0229)
}

// Total is every token of the row, cache reads included.
func (b FleetTokenBucket) Total() int64 { return b.TokensIn + b.TokensOut + b.CacheRead + b.CacheWrite }

// Fresh leaves out cache reads: the tokens the surge thresholds count (spec
// 140 4.4). A busy claude lane re-reads 0.1..1.4M cached tokens a minute in
// normal work, so the total would cross 60k/min on every busy lane.
func (b FleetTokenBucket) Fresh() int64 { return b.TokensIn + b.TokensOut + b.CacheWrite }

// FleetTokenPrune is what one retention pass did.
type FleetTokenPrune struct {
	RolledDays    int `json:"rolled_days"`
	PrunedMinutes int `json:"pruned_minutes"`
	PrunedDays    int `json:"pruned_days"`
}

// FleetTokenDay is one row of fleet_token_burn_daily.
type FleetTokenDay struct {
	Day        time.Time
	BoxTag     string
	AgentID    string
	Vendor     string
	Model      string
	Minutes    int
	TokensIn   int64
	TokensOut  int64
	CacheRead  int64
	CacheWrite int64
	CostMicros float64
	Currency   string
	IsMetered  bool
	WorkTenant string // the day's latest minute's (rdb 0229)
}

// FleetTokenStore is the store half of rdb 0199. Optional: the hub answers
// unsupported, and its sweep skips it, on a store without it.
type FleetTokenStore interface {
	// RecordSamples prices and upserts samples (checked by
	// wire.DecodeFleetTokensPush) as box's rows, in one operator
	// transaction, and answers how many rows it wrote.
	RecordSamples(ctx context.Context, box string, samples []wire.FleetTokenSample) (int, error)
	// ListBuckets is every box's rows at or after since, of vendor ("" =
	// every kind), oldest first, at most FleetTokenRowsMax (the newest).
	ListBuckets(ctx context.Context, since time.Time, vendor string) ([]FleetTokenBucket, error)
	// ListDays is the daily rollups at or after since, oldest first.
	ListDays(ctx context.Context, since time.Time) ([]FleetTokenDay, error)
	// PruneOldBuckets is the retention pass at now: roll yesterday, today and
	// every day about to go into the daily table, then drop the minutes of
	// whole UTC days older than FleetTokensRetention and the days older than
	// FleetTokensDailyRetention.
	PruneOldBuckets(ctx context.Context, now time.Time) (FleetTokenPrune, error)
}

// fleetTokenCuts are the retention pass's bounds at now: minutes before
// minuteCut go (a whole UTC day, so the day rolled up is complete), days
// before dayCut go, and the rollup re-reads every minute at or after
// rollFrom (yesterday and today) plus every minute before minuteCut.
func fleetTokenCuts(now time.Time) (minuteCut, dayCut, rollFrom time.Time) {
	today := now.UTC().Truncate(24 * time.Hour)
	return now.UTC().Add(-FleetTokensRetention).Truncate(24 * time.Hour),
		now.UTC().Add(-FleetTokensDailyRetention).Truncate(24 * time.Hour),
		today.Add(-24 * time.Hour)
}

// fleetTokenPrice is one model_prices row as the pricer reads it.
type fleetTokenPrice struct {
	provider, model, kind string
	micros                int64
	currency              string
	from                  time.Time
}

// fleetTokenPricer resolves the price in force for a sample from the price
// rows of its models (both drivers load them, then share this).
type fleetTokenPricer []fleetTokenPrice

func (p fleetTokenPricer) at(provider, model, kind string, at time.Time) (fleetTokenPrice, bool) {
	var best fleetTokenPrice
	ok := false
	for _, r := range p {
		if r.provider == provider && r.model == model && r.kind == kind && !r.from.After(at) && (!ok || r.from.After(best.from)) {
			best, ok = r, true
		}
	}
	return best, ok
}

// price is a sample's cost in micros as numeric(20,6) text, its currency,
// and whether every kind it counts had a price in force at its minute. An
// unpriced sample costs "0" (spec 140 T010): its tokens still count.
func (p fleetTokenPricer) price(s wire.FleetTokenSample) (cost, currency string, priced bool) {
	provider, model := FleetTokenProvider(s.Vendor), fleetTokenModel(s.ModelName())
	if !s.IsMetered {
		return "0", "USD", false
	}
	sum := new(big.Rat)
	for _, k := range []struct {
		kind string
		n    int64
	}{{UsageKindIn, s.TokensIn}, {UsageKindOut, s.TokensOut}, {UsageKindCacheRead, s.CacheRead}, {UsageKindCacheWrite, s.CacheWrite}} {
		if k.n == 0 {
			continue
		}
		r, ok := p.at(provider, model, k.kind, s.Minute)
		if !ok || provider == "" || model == "" || (currency != "" && r.currency != currency) {
			return "0", "USD", false
		}
		currency = r.currency
		sum.Add(sum, new(big.Rat).SetFrac(new(big.Int).Mul(big.NewInt(k.n), big.NewInt(r.micros)), big.NewInt(1_000_000)))
	}
	if currency == "" { // nothing counted: a zero row, priced trivially
		return "0", "USD", true
	}
	return sum.FloatString(6), currency, true
}

// FleetTokenWindows are the read route's windows.
var FleetTokenWindows = []string{"1h", "24h", "today"}

// FleetTokenWindowStart is the first minute of window at now and the read's
// since (the window or the UTC day, whichever starts first: the KPI strip
// always shows today). ok=false: an unknown window.
func FleetTokenWindowStart(window string, now time.Time) (start, since time.Time, ok bool) {
	now = now.UTC()
	today := now.Truncate(24 * time.Hour)
	switch window {
	case "1h":
		start = now.Add(-time.Hour)
	case "24h":
		start = now.Add(-24 * time.Hour)
	case "today":
		start = today
	default:
		return time.Time{}, time.Time{}, false
	}
	start = start.Truncate(time.Minute)
	since = start
	if today.Before(since) {
		since = today
	}
	return start, since, true
}

// fleetTokenAgentAcc is one lane's fold: its newest row and its sums.
type fleetTokenAgentAcc struct {
	last                    FleetTokenBucket
	burn, fresh, one, total int64
	cost                    float64
	active, seenWindow      bool
}

// fleetTokenVendorAcc is one agent kind's fold.
type fleetTokenVendorAcc struct {
	in, out, cr, cw, burn, fresh int64
	cost                         float64
	active                       int
	metered                      int
}

// fleetTokenFold is FleetTokenSummarize's state: the window's bounds at
// now, and the sums per lane, per kind, per minute and for the fleet.
type fleetTokenFold struct {
	start, today, nowMin, burnFrom, lastMin time.Time
	agents                                  map[[2]string]*fleetTokenAgentAcc
	vendors                                 map[string]*fleetTokenVendorAcc
	hist                                    map[int64]*wire.FleetTokenMinute
	sum                                     wire.FleetTokenSummary
	burnCost                                float64
}

func newFleetTokenFold(window string, now time.Time) *fleetTokenFold {
	start, _, _ := FleetTokenWindowStart(window, now)
	nowMin := now.Truncate(time.Minute)
	f := &fleetTokenFold{start: start, today: now.Truncate(24 * time.Hour), nowMin: nowMin,
		burnFrom: nowMin.Add(-wire.FleetTokenBurnMinutes * time.Minute), lastMin: nowMin.Add(-time.Minute),
		agents: map[[2]string]*fleetTokenAgentAcc{}, vendors: map[string]*fleetTokenVendorAcc{}, hist: map[int64]*wire.FleetTokenMinute{}}
	for _, v := range wire.FleetTokenVendors {
		f.vendors[v] = &fleetTokenVendorAcc{}
	}
	return f
}

// add folds one row in. An unmetered row only marks its lane live.
func (f *fleetTokenFold) add(r FleetTokenBucket) {
	k := [2]string{r.BoxTag, r.AgentID}
	ac := f.agents[k]
	if ac == nil {
		ac = &fleetTokenAgentAcc{}
		f.agents[k] = ac
	}
	if !r.Minute.Before(ac.last.Minute) {
		ac.last = r
	}
	inWindow := !r.Minute.Before(f.start)
	ac.seenWindow = ac.seenWindow || inWindow
	ac.active = ac.active || !r.Minute.Before(f.burnFrom)
	va := f.vendors[r.Vendor]
	if va == nil || !r.IsMetered {
		return
	}
	if !r.Minute.Before(f.today) {
		ac.total += r.Total()
		ac.cost += r.CostMicros
		va.in, va.out, va.cr, va.cw = va.in+r.TokensIn, va.out+r.TokensOut, va.cr+r.CacheRead, va.cw+r.CacheWrite
		va.cost += r.CostMicros
		f.sum.TodayTotalTokens += r.Total()
		f.sum.TodayCacheRead += r.CacheRead
		f.sum.TodayTotalCost += r.CostMicros
	}
	if !r.Minute.Before(f.burnFrom) && r.Minute.Before(f.nowMin) {
		ac.burn, ac.fresh = ac.burn+r.Total(), ac.fresh+r.Fresh()
		va.burn, va.fresh = va.burn+r.Total(), va.fresh+r.Fresh()
		f.sum.BurnRateTokensPerMin += r.Total()
		f.sum.FreshTokensPerMin += r.Fresh()
		f.burnCost += r.CostMicros
	}
	if r.Minute.Equal(f.lastMin) {
		ac.one += r.Total()
	}
	if inWindow {
		h := f.hist[r.Minute.Unix()]
		if h == nil {
			h = &wire.FleetTokenMinute{}
			f.hist[r.Minute.Unix()] = h
		}
		h.Tokens, h.Fresh, h.Cost = h.Tokens+r.Total(), h.Fresh+r.Fresh(), h.Cost+r.CostMicros
	}
	if r.Priced && f.sum.Currency == "" {
		f.sum.Currency = r.Currency
	}
}

// perMin is a burn window's sum as tokens per minute.
func perMin(n int64) int64 { return int64(math.Round(float64(n) / wire.FleetTokenBurnMinutes)) }

// agentRows is the lanes seen in the window or live now, burn rate
// descending (unmetered last), counting the live ones into the summary.
func (f *fleetTokenFold) agentRows() []wire.AgentTokenBurn {
	out := []wire.AgentTokenBurn{}
	for _, ac := range f.agents {
		if !ac.seenWindow && !ac.active {
			continue
		}
		l := ac.last
		a := wire.AgentTokenBurn{AgentID: l.AgentID, Vendor: l.Vendor, Box: l.BoxTag, IsMetered: l.IsMetered,
			Priced: l.Priced, LastActive: l.Minute.Format(time.RFC3339)}
		if l.Model != "" {
			m := l.Model
			a.Model = &m
		}
		if l.IsMetered {
			burn, fresh, one, total, cost := perMin(ac.burn), perMin(ac.fresh), ac.one, ac.total, money(ac.cost)
			a.BurnRateTokensPerMin, a.FreshTokensPerMin, a.BurnRate1m, a.TodayTotalTokens, a.TodayCost = &burn, &fresh, &one, &total, &cost
		}
		if ac.active {
			f.countLive(l)
		}
		out = append(out, a)
	}
	rate := func(p *int64) int64 {
		if p == nil {
			return -1
		}
		return *p
	}
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if ra, rb := rate(a.BurnRateTokensPerMin), rate(b.BurnRateTokensPerMin); ra != rb {
			return ra > rb
		}
		if a.AgentID != b.AgentID {
			return a.AgentID < b.AgentID
		}
		return a.Box < b.Box
	})
	return out
}

// countLive counts one live lane (its newest row l) into its kind and the summary.
func (f *fleetTokenFold) countLive(l FleetTokenBucket) {
	f.sum.ActiveAgents++
	if va := f.vendors[l.Vendor]; va != nil {
		va.active++
		if l.IsMetered {
			va.metered++
		}
	}
	switch {
	case !l.IsMetered:
		f.sum.UnmeteredAgents++
	case !l.Priced && l.Total() > 0:
		f.sum.UnpricedAgents++
	}
}

// vendorRows is every kind in wire.FleetTokenVendors order; unmetered kind's sums are null.
func (f *fleetTokenFold) vendorRows() []wire.VendorTokenBurn {
	out := []wire.VendorTokenBurn{}
	for _, v := range wire.FleetTokenVendors {
		va := f.vendors[v]
		vb := wire.VendorTokenBurn{Vendor: v, ActiveAgents: va.active, Status: "idle"}
		if va.active > 0 && (v == wire.FleetBurnVendorUnmetered || va.metered == 0) {
			vb.Status = "unmetered"
		} else {
			if va.active > 0 {
				vb.Status = "metered"
			}
			burn, fresh, total, cost := perMin(va.burn), perMin(va.fresh), va.in+va.out+va.cr+va.cw, money(va.cost)
			in, o, cr, cw := va.in, va.out, va.cr, va.cw
			vb.BurnRateTokensPerMin, vb.FreshTokensPerMin, vb.TodayTotalTokens, vb.TodayCost = &burn, &fresh, &total, &cost
			vb.TodayTokensIn, vb.TodayTokensOut, vb.TodayCacheRead, vb.TodayCacheWrite = &in, &o, &cr, &cw
		}
		out = append(out, vb)
	}
	return out
}

// history is one row per minute of the window, a minute with no row as 0.
func (f *fleetTokenFold) history() []wire.FleetTokenMinute {
	out := []wire.FleetTokenMinute{}
	for m := f.start; !m.After(f.nowMin); m = m.Add(time.Minute) {
		h := wire.FleetTokenMinute{Minute: m.Format(time.RFC3339)}
		if got := f.hist[m.Unix()]; got != nil {
			h.Tokens, h.Fresh, h.Cost = got.Tokens, got.Fresh, money(got.Cost)
		}
		out = append(out, h)
	}
	return out
}

// FleetTokenSummarize folds rows (ListBuckets since FleetTokenWindowStart's
// since) into the read answer at now. Both drivers and the route share it.
func FleetTokenSummarize(rows []FleetTokenBucket, window string, now time.Time) wire.FleetTokenSummaryResponse {
	now = now.UTC()
	f := newFleetTokenFold(window, now)
	for _, r := range rows {
		f.add(r)
	}
	out := wire.FleetTokenSummaryResponse{AsOf: now.Format(time.RFC3339), Window: window,
		ByAgent: f.agentRows(), ByVendor: f.vendorRows(), History: f.history()}
	s := f.sum
	if s.Currency == "" {
		s.Currency = "USD"
	}
	s.BurnRateTokensPerMin, s.FreshTokensPerMin = perMin(s.BurnRateTokensPerMin), perMin(s.FreshTokensPerMin)
	s.BurnRateCostPerHour = money(f.burnCost / wire.FleetTokenBurnMinutes * 60)
	s.TodayTotalCost = money(s.TodayTotalCost)
	out.Summary = s
	return out
}

// money is micros as currency units, to the micro.
func money(micros float64) float64 { return math.Round(micros) / 1e6 }

// The Memory driver keeps its rows beside the store (memory.go is shared by
// every lane), like box stats.
var (
	memFleetTokensMu sync.Mutex
	memFleetTokens   = map[*Memory]map[[3]string]FleetTokenBucket{} // (box, agent, minute)
	memFleetDays     = map[*Memory]map[[3]string]FleetTokenDay{}    // (day, box, agent)
)

func fleetTokenKey(box, agent string, minute time.Time) [3]string {
	return [3]string{box, agent, minute.UTC().Format(time.RFC3339)}
}

// memFleetPricer is the Memory store's price rows as the pricer reads them.
func (s *Memory) memFleetPricer() fleetTokenPricer {
	s.mu.Lock()
	defer s.mu.Unlock()
	out := make(fleetTokenPricer, 0, len(memPrices[s]))
	for _, p := range memPrices[s] {
		out = append(out, fleetTokenPrice{p.Provider, p.Model, p.Kind, p.MicrosPerMillion, p.Currency, p.ValidFrom})
	}
	return out
}

// RecordSamples is FleetTokenStore on Memory (see the interface).
func (s *Memory) RecordSamples(_ context.Context, box string, samples []wire.FleetTokenSample) (int, error) {
	pricer := s.memFleetPricer()
	memFleetTokensMu.Lock()
	defer memFleetTokensMu.Unlock()
	if memFleetTokens[s] == nil {
		memFleetTokens[s] = map[[3]string]FleetTokenBucket{}
	}
	for _, x := range samples {
		cost, cur, priced := pricer.price(x)
		c, _ := new(big.Rat).SetString(cost)
		f, _ := c.Float64()
		memFleetTokens[s][fleetTokenKey(box, x.AgentID, x.Minute)] = FleetTokenBucket{BoxTag: box, AgentID: x.AgentID, Vendor: x.Vendor,
			Model: x.ModelName(), Minute: x.Minute.UTC(), TokensIn: x.TokensIn, TokensOut: x.TokensOut, CacheRead: x.CacheRead,
			CacheWrite: x.CacheWrite, CostMicros: f, Currency: cur, Priced: priced, IsMetered: x.IsMetered, WorkTenant: x.WorkTenant}
	}
	return len(samples), nil
}

func sortFleetBuckets(out []FleetTokenBucket) {
	sort.Slice(out, func(i, j int) bool {
		a, b := out[i], out[j]
		if !a.Minute.Equal(b.Minute) {
			return a.Minute.Before(b.Minute)
		}
		if a.BoxTag != b.BoxTag {
			return a.BoxTag < b.BoxTag
		}
		return a.AgentID < b.AgentID
	})
}

// ListBuckets is FleetTokenStore on Memory.
func (s *Memory) ListBuckets(_ context.Context, since time.Time, vendor string) ([]FleetTokenBucket, error) {
	memFleetTokensMu.Lock()
	defer memFleetTokensMu.Unlock()
	out := []FleetTokenBucket{}
	for _, b := range memFleetTokens[s] {
		if !b.Minute.Before(since) && (vendor == "" || b.Vendor == vendor) {
			out = append(out, b)
		}
	}
	sortFleetBuckets(out)
	if len(out) > FleetTokenRowsMax {
		out = out[len(out)-FleetTokenRowsMax:]
	}
	return out, nil
}

// ListDays is FleetTokenStore on Memory.
func (s *Memory) ListDays(_ context.Context, since time.Time) ([]FleetTokenDay, error) {
	memFleetTokensMu.Lock()
	defer memFleetTokensMu.Unlock()
	out := []FleetTokenDay{}
	for _, d := range memFleetDays[s] {
		if !d.Day.Before(since.UTC().Truncate(24 * time.Hour)) {
			out = append(out, d)
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if !out[i].Day.Equal(out[j].Day) {
			return out[i].Day.Before(out[j].Day)
		}
		return out[i].BoxTag+"\x00"+out[i].AgentID < out[j].BoxTag+"\x00"+out[j].AgentID
	})
	return out, nil
}

// PruneOldBuckets is FleetTokenStore on Memory: the same cuts as Postgres.
func (s *Memory) PruneOldBuckets(_ context.Context, now time.Time) (FleetTokenPrune, error) {
	minuteCut, dayCut, rollFrom := fleetTokenCuts(now)
	memFleetTokensMu.Lock()
	defer memFleetTokensMu.Unlock()
	if memFleetDays[s] == nil {
		memFleetDays[s] = map[[3]string]FleetTokenDay{}
	}
	var res FleetTokenPrune
	rolled := map[[3]string]FleetTokenDay{}
	var latest = map[[3]string]time.Time{}
	for _, b := range memFleetTokens[s] {
		if b.Minute.Before(rollFrom) && !b.Minute.Before(minuteCut) {
			continue
		}
		day := b.Minute.Truncate(24 * time.Hour)
		k := [3]string{day.Format(time.DateOnly), b.BoxTag, b.AgentID}
		d := rolled[k]
		d.Day, d.BoxTag, d.AgentID = day, b.BoxTag, b.AgentID
		if !b.Minute.Before(latest[k]) {
			latest[k], d.Vendor, d.Model, d.WorkTenant = b.Minute, b.Vendor, b.Model, b.WorkTenant
		}
		if d.Currency == "" || b.Priced {
			d.Currency = b.Currency
		}
		d.Minutes++
		d.TokensIn, d.TokensOut, d.CacheRead, d.CacheWrite = d.TokensIn+b.TokensIn, d.TokensOut+b.TokensOut, d.CacheRead+b.CacheRead, d.CacheWrite+b.CacheWrite
		d.CostMicros += b.CostMicros
		d.IsMetered = d.IsMetered || b.IsMetered
		rolled[k] = d
	}
	for k, d := range rolled {
		memFleetDays[s][k] = d
	}
	res.RolledDays = len(rolled)
	for k, b := range memFleetTokens[s] {
		if b.Minute.Before(minuteCut) {
			delete(memFleetTokens[s], k)
			res.PrunedMinutes++
		}
	}
	for k, d := range memFleetDays[s] {
		if d.Day.Before(dayCut) {
			delete(memFleetDays[s], k)
			res.PrunedDays++
		}
	}
	return res, nil
}

var _ FleetTokenStore = (*Memory)(nil)

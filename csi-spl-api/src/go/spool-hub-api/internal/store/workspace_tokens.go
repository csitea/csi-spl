package store

import (
	"context"
	"fmt"
	"math"
	"regexp"
	"sort"
	"time"

	"github.com/jackc/pgx/v5"
)

// A workspace's own token costs (spec 140 section 3.10, SPL-3565; owner
// HUM-10, t1 f3ed0eed, msgs 1bb1f74b and 96d69790): one month of the fleet's
// token burn (rdb 0199) summed per (workspace the lane worked for, vendor),
// for the Costs tab. The hub stamps work_tenant when it writes a minute (rdb
// 0229); NULL is the operator workspace's own work. The rows stay operator
// scope: the read runs there and filters on the column, and the hub's cost
// route decides who may ask for which workspace (a workspace's members its
// own, the operator workspace's admin every one).
//
// The money is the burn's price at write time (spec 140 3.3), a list-price
// equivalent, never a paid amount (spec 123 Q-4): USD rows only (every row
// on prd is USD, 2026-10-26). Days the minutes still hold (FleetTokensRetention)
// are read from the minutes, older ones from the daily rollup, so no day is
// counted twice.

// WorkspaceTokenQuery is one month of one workspace's burn, or of every
// workspace's (Workspace ""). Operator names the operator workspace, which
// the NULL rows belong to. From and To are UTC days, To exclusive; Now sets
// the minutes / daily split.
type WorkspaceTokenQuery struct {
	Operator  string
	Workspace string
	From      string
	To        string
	Now       time.Time
}

// WorkspaceTokenPart is one (workspace, vendor) of the month: every token
// (cache reads included, spec 140's total), the list-price USD micros and how
// many days of the month have a row.
type WorkspaceTokenPart struct {
	Workspace     string
	Vendor        string
	Tokens        int64
	ListUSDMicros int64
	Days          int
}

// WorkspaceTokens is the store half. Optional: the cost route reads no
// token part on a store without it.
type WorkspaceTokens interface {
	// WorkspaceTokenMonth reads q's month, by workspace then vendor.
	WorkspaceTokenMonth(ctx context.Context, q WorkspaceTokenQuery) ([]WorkspaceTokenPart, error)
}

var (
	_ WorkspaceTokens = (*Postgres)(nil)
	_ WorkspaceTokens = (*Memory)(nil)
)

// workTenantRe is rdb 0229's work_tenant CHECK.
var workTenantRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,31}$`)

// ValidWorkTenant is whether id passes rdb 0229's work_tenant CHECK: the hub
// stamps no other, so a stamp never fails a push.
func ValidWorkTenant(id string) bool { return workTenantRe.MatchString(id) }

// checkWorkspaceTokenQuery names the first thing q may not carry ("" = fine).
func checkWorkspaceTokenQuery(q WorkspaceTokenQuery) (from, to, split time.Time, why string) {
	from, err1 := time.Parse(time.DateOnly, q.From)
	to, err2 := time.Parse(time.DateOnly, q.To)
	switch {
	case !workTenantRe.MatchString(q.Operator):
		return from, to, split, "the operator workspace is required"
	case q.Workspace != "" && !workTenantRe.MatchString(q.Workspace):
		return from, to, split, "workspace must be a workspace id"
	case err1 != nil || err2 != nil || !to.After(from):
		return from, to, split, "from and to must be UTC days YYYY-MM-DD, from before to"
	case to.Sub(from) > 31*24*time.Hour:
		return from, to, split, "at most one month"
	}
	split, _, _ = fleetTokenCuts(q.Now)
	return from, to, split, ""
}

// workspaceBurnMonthSQL sums the month: minutes from max(from, split), days
// before min(to, split). $1 operator, $2..$5 the bounds; the %s is the
// workspace predicate (workspaceTokenFilter), never caller text.
const workspaceBurnMonthSQL = `WITH b AS (
	SELECT coalesce(work_tenant, $1) AS ws, vendor, (minute_bucket AT TIME ZONE 'UTC')::date AS day,
		tokens_in + tokens_out + cache_read + cache_write AS tokens, CASE WHEN currency = 'USD' THEN cost_micros ELSE 0 END AS usd
	FROM fleet_token_burn_events
	WHERE minute_bucket >= greatest($2::timestamptz, $4::timestamptz) AND minute_bucket < $3::timestamptz AND %[1]s
	UNION ALL
	SELECT coalesce(work_tenant, $1), vendor, day_bucket,
		tokens_in + tokens_out + cache_read + cache_write, CASE WHEN currency = 'USD' THEN cost_micros ELSE 0 END
	FROM fleet_token_burn_daily
	WHERE day_bucket >= $5::date AND day_bucket < least($6::date, $7::date) AND %[1]s)
SELECT ws, vendor, sum(tokens)::bigint, round(sum(usd))::bigint, count(DISTINCT day)::int
FROM b GROUP BY ws, vendor ORDER BY ws, vendor`

// workspaceTokenFilter is the predicate of q's workspace: a customer
// workspace's own rows (the partial index), the operator's NULL rows, or all.
func workspaceTokenFilter(q WorkspaceTokenQuery) (string, []any) {
	switch {
	case q.Workspace == "":
		return "true", nil
	case q.Workspace == q.Operator:
		return "work_tenant IS NULL", nil
	}
	return "work_tenant = $8", []any{q.Workspace}
}

// WorkspaceTokenMonth is WorkspaceTokens on Postgres, in the operator scope.
func (s *Postgres) WorkspaceTokenMonth(ctx context.Context, q WorkspaceTokenQuery) ([]WorkspaceTokenPart, error) {
	from, to, split, why := checkWorkspaceTokenQuery(q)
	if why != "" {
		return nil, fmt.Errorf("workspace tokens: %s", why)
	}
	pred, extra := workspaceTokenFilter(q)
	args := append([]any{q.Operator, from, to, split, q.From, q.To, split.Format(time.DateOnly)}, extra...)
	out := []WorkspaceTokenPart{}
	err := s.asOperatorQuery(ctx, fmt.Sprintf(workspaceBurnMonthSQL, pred), args, func(rows pgx.Rows) error {
		var p WorkspaceTokenPart
		if err := rows.Scan(&p.Workspace, &p.Vendor, &p.Tokens, &p.ListUSDMicros, &p.Days); err != nil {
			return err
		}
		out = append(out, p)
		return nil
	})
	return out, err
}

// WorkspaceTokenMonth is WorkspaceTokens on Memory: the same split and sums.
func (s *Memory) WorkspaceTokenMonth(_ context.Context, q WorkspaceTokenQuery) ([]WorkspaceTokenPart, error) {
	from, to, split, why := checkWorkspaceTokenQuery(q)
	if why != "" {
		return nil, fmt.Errorf("workspace tokens: %s", why)
	}
	type key struct{ ws, vendor string }
	sums := map[key]*WorkspaceTokenPart{}
	money := map[key]float64{}
	days := map[key]map[string]bool{}
	add := func(ws, vendor string, day time.Time, tokens int64, usd float64) {
		if ws == "" {
			ws = q.Operator
		}
		if q.Workspace != "" && ws != q.Workspace {
			return
		}
		k := key{ws, vendor}
		if sums[k] == nil {
			sums[k], days[k] = &WorkspaceTokenPart{Workspace: ws, Vendor: vendor}, map[string]bool{}
		}
		sums[k].Tokens += tokens
		money[k] += usd
		days[k][day.Format(time.DateOnly)] = true
	}
	usd := func(cur string, micros float64) float64 {
		if cur != "USD" {
			return 0
		}
		return micros
	}
	memFleetTokensMu.Lock()
	for _, b := range memFleetTokens[s] {
		if !b.Minute.Before(from) && !b.Minute.Before(split) && b.Minute.Before(to) {
			add(b.WorkTenant, b.Vendor, b.Minute.Truncate(24*time.Hour), b.Total(), usd(b.Currency, b.CostMicros))
		}
	}
	for _, d := range memFleetDays[s] {
		if !d.Day.Before(from) && d.Day.Before(to) && d.Day.Before(split) {
			add(d.WorkTenant, d.Vendor, d.Day, d.TokensIn+d.TokensOut+d.CacheRead+d.CacheWrite, usd(d.Currency, d.CostMicros))
		}
	}
	memFleetTokensMu.Unlock()
	out := make([]WorkspaceTokenPart, 0, len(sums))
	for k, p := range sums {
		p.Days, p.ListUSDMicros = len(days[k]), int64(math.Round(money[k]))
		out = append(out, *p)
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Workspace != out[j].Workspace {
			return out[i].Workspace < out[j].Workspace
		}
		return out[i].Vendor < out[j].Vendor
	})
	return out, nil
}

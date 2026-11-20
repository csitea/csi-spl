package store

import (
	"context"
	"fmt"

	"github.com/jackc/pgx/v5"
)

// The Human part of the project's cost (spec 123 section 13, row P02; spec
// 107 21.4 step 5, 21.5): a workspace's approved minutes of each day priced
// at each member's own price IN FORCE ON THAT DAY (member_hourly_prices,
// rdb 0295: the row with the latest valid_from on or before the entry's
// day), summed per (day, currency). No member column leaves the read (107
// 21.7): the sum is per day only.
//
// Money: the amount is in the price's currency, converted per day at the
// fx_rates rate of that day, else the last one before it, an ECB row first
// on a tie (13.4, the month read's rule). A member with no price on the day
// is the (day, NULL currency) row: its minutes count, its money is NULL
// (13.5 "unpriced"). A currency with no rate on or before the day leaves
// that day's amount NULL in the currencies that need the rate, never a
// guess.
//
// Two choices the spec leaves open (for the spec's next version):
//  1. Approved means hours_entries state approved, the worker's or the
//     foreman's tap (107 FR-15); a frozen or final period is not required.
//  2. Absence rows (kind absence, 107 FR-30) are no time on the project and
//     are left out; work, travel and wait count.

// CostProjectHumanQuery is one month of one workspace's own hours: From and
// To are days, To exclusive; Currency is the reader's second currency (""
// = DefaultSecondCurrency).
type CostProjectHumanQuery struct {
	Tenant   string
	From     string
	To       string
	Currency string
}

// CostProjectHumanDay is one (day, currency) of the approved minutes.
// Currency nil = the minutes of members with no price that day (every
// amount nil). AmountMicros is in Currency; the others nil where no rate
// made them.
type CostProjectHumanDay struct {
	Day          string  `json:"day"`
	Currency     *string `json:"currency"`
	Minutes      int64   `json:"minutes"`
	AmountMicros *int64  `json:"amount_micros"`
	USDMicros    *int64  `json:"usd_micros"`
	EURMicros    *int64  `json:"eur_micros"`
	SecondMicros *int64  `json:"second_micros"`
}

// CostProjectHumanRead is the store half of the Human part. Optional: a
// store without it leaves Human not_tracked.
type CostProjectHumanRead interface {
	// CostProjectHumanDays reads q under q.Tenant's scope, by day then
	// currency (the unpriced row first).
	CostProjectHumanDays(ctx context.Context, q CostProjectHumanQuery) ([]CostProjectHumanDay, error)
}

var _ CostProjectHumanRead = (*Postgres)(nil)

// costProjectHumanDays prices each approved entry at the price in force on
// its day ($1 workspace, $2..$3 the days, $4 the second currency). A
// package var so the red control can price at today's price
// (TestCostProjectHumanSum).
var costProjectHumanDays = `WITH e AS (
	SELECT h.day, h.minutes, p.amount_micros, p.currency
	FROM hours_entries h
	LEFT JOIN LATERAL (SELECT m.amount_micros, m.currency FROM member_hourly_prices m
		WHERE m.tenant_id = h.tenant_id AND m.member_id = h.member_id AND m.valid_from <= h.day
		ORDER BY m.valid_from DESC LIMIT 1) p ON true
	WHERE h.tenant_id = $1 AND h.day >= $2::date AND h.day < $3::date
		AND h.state = 'approved' AND h.kind <> 'absence'
), d AS (
	SELECT day, currency, sum(minutes)::bigint AS minutes, sum(minutes::numeric * amount_micros) / 60 AS amount
	FROM e GROUP BY day, currency
), x AS (
	SELECT d.*, CASE WHEN d.currency = 'USD' THEN d.amount ELSE d.amount / fc.rate END AS usd
	FROM d LEFT JOIN LATERAL (SELECT r.rate FROM fx_rates r WHERE r.quote = d.currency AND r.day <= d.day
		ORDER BY r.day DESC, r.source = 'ECB' DESC LIMIT 1) fc ON true
)
SELECT to_char(x.day, 'YYYY-MM-DD'), x.currency::text, x.minutes, round(x.amount)::bigint, round(x.usd)::bigint,
	round(CASE WHEN x.currency = 'EUR' THEN x.amount ELSE x.usd * fe.rate END)::bigint,
	round(CASE WHEN x.currency = $4 THEN x.amount WHEN $4 = 'USD' THEN x.usd ELSE x.usd * fs.rate END)::bigint
FROM x
LEFT JOIN LATERAL (SELECT r.rate FROM fx_rates r WHERE r.quote = 'EUR' AND r.day <= x.day
	ORDER BY r.day DESC, r.source = 'ECB' DESC LIMIT 1) fe ON true
LEFT JOIN LATERAL (SELECT r.rate FROM fx_rates r WHERE r.quote = $4 AND r.day <= x.day
	ORDER BY r.day DESC, r.source = 'ECB' DESC LIMIT 1) fs ON true
ORDER BY x.day, x.currency NULLS FIRST`

// CostProjectHumanDays is CostProjectHumanRead on Postgres.
func (s *Postgres) CostProjectHumanDays(ctx context.Context, q CostProjectHumanQuery) ([]CostProjectHumanDay, error) {
	if why := CheckCostMonthQuery(CostMonthQuery{Tenant: q.Tenant, From: q.From, To: q.To, Currency: q.Currency}); why != "" {
		return nil, fmt.Errorf("cost project human: %s", why)
	}
	cur := q.Currency
	if cur == "" {
		cur = DefaultSecondCurrency
	}
	out := []CostProjectHumanDay{}
	err := s.inTenant(ctx, q.Tenant, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, costProjectHumanDays, q.Tenant, q.From, q.To, cur)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (d CostProjectHumanDay, err error) {
			err = r.Scan(&d.Day, &d.Currency, &d.Minutes, &d.AmountMicros, &d.USDMicros, &d.EURMicros, &d.SecondMicros)
			return d, err
		})
		return err
	})
	return out, err
}

// costProjectHumanPart is the Human part of days (one or more months): the
// known amounts summed per currency, every minute counted, the minutes
// with no price named. A day with no amount in some currency is unpriced
// and left out of that currency's sum (13.5); no day at all is a known 0.
func costProjectHumanPart(days []CostProjectHumanDay) CostProjectPart {
	var s costProjectSum
	var minutes, unpricedMin int64
	for _, d := range days {
		s.lines++
		minutes += d.Minutes
		if d.AmountMicros == nil {
			unpricedMin += d.Minutes
		}
		s.usd, s.hasUSD = costProjectHumanAdd(s.usd, s.hasUSD, d.USDMicros)
		s.eur, s.hasEUR = costProjectHumanAdd(s.eur, s.hasEUR, d.EURMicros)
		s.second, s.hasSec = costProjectHumanAdd(s.second, s.hasSec, d.SecondMicros)
		if d.USDMicros == nil || d.EURMicros == nil || d.SecondMicros == nil {
			s.unpriced++
		}
	}
	empty := s.lines == 0
	p := CostProjectPart{Part: CostProjectHuman, Lines: s.lines, Unpriced: s.unpriced, Completeness: CostProjectComplete,
		CostProjectMoney: CostProjectMoney{USDMicros: costProjectAmount(s.usd, s.hasUSD || empty),
			EURMicros:    costProjectAmount(s.eur, s.hasEUR || empty),
			SecondMicros: costProjectAmount(s.second, s.hasSec || empty)},
		Minutes: &minutes, UnpricedMinutes: &unpricedMin}
	if s.unpriced > 0 {
		p.Completeness = CostProjectUnpriced
	}
	return p
}

// costProjectHumanAdd adds v to sum when v is known.
func costProjectHumanAdd(sum int64, has bool, v *int64) (int64, bool) {
	if v == nil {
		return sum, has
	}
	return sum + *v, true
}

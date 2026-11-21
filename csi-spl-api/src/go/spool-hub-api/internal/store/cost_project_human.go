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
// Pending approval (13.5, 107 21.4 step 6): a minute is priced only when
// its entry is approved AND the member's hours_periods row holding the day
// is frozen or approved (final). Every other entry that is not rejected
// (approved in an open or returned period, proposed, disputed, 107 FR-23)
// is the (day, pending) row: its minutes count, its money is NULL, so a
// number that could still move is never shown as complete.
//
// Absence rows (kind absence, 107 FR-30) are no time on the project and
// are left out; work, travel and wait count.

// CostProjectHumanQuery is one month of one workspace's own hours: From and
// To are days, To exclusive; Currency is the reader's second currency (""
// = DefaultSecondCurrency).
type CostProjectHumanQuery struct {
	Tenant   string
	From     string
	To       string
	Currency string
}

// CostProjectHumanDay is one (day, currency) of the minutes. Pending = the
// minutes not yet approved in a frozen or final period; Currency nil = those
// and the minutes of members with no price that day (every amount nil).
// AmountMicros is in Currency; the others nil where no rate made them.
type CostProjectHumanDay struct {
	Day          string  `json:"day"`
	Pending      bool    `json:"pending"`
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
	// CostProjectHumanDays reads q under q.Tenant's scope, by day, then the
	// final rows before the pending one, then currency (the unpriced first).
	CostProjectHumanDays(ctx context.Context, q CostProjectHumanQuery) ([]CostProjectHumanDay, error)
}

var _ CostProjectHumanRead = (*Postgres)(nil)

// costProjectHumanDays prices each final entry at the price in force on
// its day ($1 workspace, $2..$3 the days, $4 the second currency); the
// pending ones count unpriced. A package var so the red controls can price
// at today's price and drop the period guard (TestCostProjectHumanSum).
var costProjectHumanDays = `WITH f AS (
	SELECT h.day, h.minutes, h.member_id, h.state = 'approved'
		AND EXISTS (SELECT 1 FROM hours_periods hp WHERE hp.tenant_id = h.tenant_id AND hp.member_id = h.member_id
			AND h.day BETWEEN hp.period_start AND hp.period_end AND hp.state IN ('frozen', 'approved')) AS final
	FROM hours_entries h
	WHERE h.tenant_id = $1 AND h.day >= $2::date AND h.day < $3::date
		AND h.state <> 'rejected' AND h.kind <> 'absence'
), e AS (
	SELECT f.day, f.minutes, NOT f.final AS pending, p.amount_micros, p.currency
	FROM f
	LEFT JOIN LATERAL (SELECT m.amount_micros, m.currency FROM member_hourly_prices m
		WHERE f.final AND m.tenant_id = $1 AND m.member_id = f.member_id AND m.valid_from <= f.day
		ORDER BY m.valid_from DESC LIMIT 1) p ON true
), d AS (
	SELECT day, pending, currency, sum(minutes)::bigint AS minutes, sum(minutes::numeric * amount_micros) / 60 AS amount
	FROM e GROUP BY day, pending, currency
), x AS (
	SELECT d.*, CASE WHEN d.currency = 'USD' THEN d.amount ELSE d.amount / fc.rate END AS usd
	FROM d LEFT JOIN LATERAL (SELECT r.rate FROM fx_rates r WHERE r.quote = d.currency AND r.day <= d.day
		ORDER BY r.day DESC, r.source = 'ECB' DESC LIMIT 1) fc ON true
)
SELECT to_char(x.day, 'YYYY-MM-DD'), x.pending, x.currency::text, x.minutes, round(x.amount)::bigint, round(x.usd)::bigint,
	round(CASE WHEN x.currency = 'EUR' THEN x.amount ELSE x.usd * fe.rate END)::bigint,
	round(CASE WHEN x.currency = $4 THEN x.amount WHEN $4 = 'USD' THEN x.usd ELSE x.usd * fs.rate END)::bigint
FROM x
LEFT JOIN LATERAL (SELECT r.rate FROM fx_rates r WHERE r.quote = 'EUR' AND r.day <= x.day
	ORDER BY r.day DESC, r.source = 'ECB' DESC LIMIT 1) fe ON true
LEFT JOIN LATERAL (SELECT r.rate FROM fx_rates r WHERE r.quote = $4 AND r.day <= x.day
	ORDER BY r.day DESC, r.source = 'ECB' DESC LIMIT 1) fs ON true
ORDER BY x.day, x.pending, x.currency NULLS FIRST`

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
			err = r.Scan(&d.Day, &d.Pending, &d.Currency, &d.Minutes, &d.AmountMicros, &d.USDMicros, &d.EURMicros, &d.SecondMicros)
			return d, err
		})
		return err
	})
	return out, err
}

// costProjectHumanPart is the Human part of days (one or more months): the
// known amounts summed per currency, every minute counted, the minutes
// with no price named, those pending approval among them. A day with no
// amount in some currency is unpriced and left out of that currency's sum
// (13.5); no day at all is a known 0.
func costProjectHumanPart(days []CostProjectHumanDay) CostProjectPart {
	var s costProjectSum
	var minutes, unpricedMin, pendingMin int64
	for _, d := range days {
		s.lines++
		minutes += d.Minutes
		if d.AmountMicros == nil {
			unpricedMin += d.Minutes
		}
		if d.Pending {
			pendingMin += d.Minutes
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
		Minutes: &minutes, UnpricedMinutes: &unpricedMin, PendingMinutes: &pendingMin}
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

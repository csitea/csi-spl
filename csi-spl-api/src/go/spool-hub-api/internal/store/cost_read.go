package store

import (
	"context"
	"fmt"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
)

// The read side of cost tracking (spec 123 sections 5 and 5.1, build lane
// 4b): one calendar month of rdb 0166's cost_lines summed per part, and the
// month's cost_coverage per source, for the Monitoring Costs tab (owner
// HUM-10, t1 dbf2f39b msgs 6cab186b, a54b9e74). Who reads what is the
// caller's scope (Q-1 = A): the operator workspace reads the ESTATE rows
// (tenant_id NULL) beside its own, under the operator scope; any other
// workspace reads its own rows under its tenant scope, where RLS hides every
// estate row whatever the statement asks for.

// CostMonthQuery is one month of one workspace. From and To are UTC days,
// To exclusive; CoverTo ("" = To) ends the coverage count, so a month so far
// counts only the days that ended. Estate asks for the estate rows too: only
// the operator workspace's caller sets it.
type CostMonthQuery struct {
	Tenant  string
	Estate  bool
	From    string
	To      string
	CoverTo string
}

// CostPart is one row of the month table: the live (not superseded) lines of
// one (scope, source, project_or_vendor, kind, origin) summed. Units are the
// count (tokens, agent-seconds); the money columns are what was paid in USD
// and EUR (Q-6). ListValueMicros is nil while no line carries a list-price
// equivalent (Q-4). Days is how many days of the month have a line.
type CostPart struct {
	Estate          bool    `json:"estate"`
	Source          string  `json:"source"`
	ProjectOrVendor string  `json:"project_or_vendor"`
	Kind            string  `json:"kind"`
	Origin          string  `json:"origin"`
	Units           float64 `json:"units"`
	USDMicros       int64   `json:"usd_micros"`
	EURMicros       int64   `json:"eur_micros"`
	ListValueMicros *int64  `json:"list_value_micros"`
	Days            int     `json:"days"`
}

// CostSourceDays is one source's cost_coverage rows in the month, per state.
type CostSourceDays struct {
	Source  string `json:"source"`
	OK      int    `json:"ok"`
	Partial int    `json:"partial"`
	Missing int    `json:"missing"`
}

// CostMonth is what CostRead answers for one month.
type CostMonth struct {
	Parts    []CostPart
	Coverage []CostSourceDays
}

// CostRead is the store half of the cost report. Optional: the hub's read
// route answers 501 on a store without it.
type CostRead interface {
	// CostMonthRead reads q's month in one transaction: the parts (estate
	// first, then by source, project, kind, origin) and the coverage of every
	// source (estate) or of the sources the workspace's own parts name (a
	// workspace never learns the estate's source names).
	CostMonthRead(ctx context.Context, q CostMonthQuery) (CostMonth, error)
}

var _ CostRead = (*Postgres)(nil)

// costMonthParts sums the month per part. $4 admits the estate rows; under a
// tenant scope RLS hides them even with $4 true (TestCostMonthReadRLS).
const costMonthParts = `SELECT tenant_id IS NULL, source, project_or_vendor, kind, origin,
	coalesce(sum(units), 0)::float8, coalesce(sum(usd_micros), 0)::bigint, coalesce(sum(eur_micros), 0)::bigint,
	sum(list_value_micros)::bigint, count(DISTINCT day)::int
FROM cost_lines
WHERE day >= $1::date AND day < $2::date AND superseded_by IS NULL
	AND (tenant_id = $3 OR ($4 AND tenant_id IS NULL))
GROUP BY 1, 2, 3, 4, 5
ORDER BY 1 DESC, 2, 3, 4, 5`

// costMonthCoverage counts the month's coverage rows per source and state;
// $3 NULL = every source, else only those named.
const costMonthCoverage = `SELECT source,
	count(*) FILTER (WHERE state = 'ok')::int, count(*) FILTER (WHERE state = 'partial')::int,
	count(*) FILTER (WHERE state = 'missing')::int
FROM cost_coverage
WHERE day >= $1::date AND day < $2::date AND ($3::text[] IS NULL OR source = ANY($3))
GROUP BY source ORDER BY source`

// CheckCostMonthQuery names the first thing q may not carry ("" = fine).
func CheckCostMonthQuery(q CostMonthQuery) string {
	from, err1 := time.Parse(time.DateOnly, q.From)
	to, err2 := time.Parse(time.DateOnly, q.To)
	cover, err3 := to, error(nil)
	if q.CoverTo != "" {
		cover, err3 = time.Parse(time.DateOnly, q.CoverTo)
	}
	switch {
	case checkTenant(q.Tenant) != nil:
		return "a workspace is required"
	case err1 != nil || err2 != nil || !to.After(from):
		return "from and to must be UTC days YYYY-MM-DD, from before to"
	case err3 != nil || cover.Before(from) || cover.After(to):
		return "cover_to must be a UTC day from..to"
	case to.Sub(from) > 31*24*time.Hour:
		return "at most one month"
	}
	return ""
}

// CostMonthRead is CostRead on Postgres (see the interface).
func (s *Postgres) CostMonthRead(ctx context.Context, q CostMonthQuery) (CostMonth, error) {
	if why := CheckCostMonthQuery(q); why != "" {
		return CostMonth{}, fmt.Errorf("cost month: %s", why)
	}
	var out CostMonth
	read := func(tx pgx.Tx) (err error) {
		out, err = costMonthIn(ctx, tx, q)
		return err
	}
	if q.Estate {
		return out, s.asOperator(ctx, read)
	}
	return out, s.inTenant(ctx, q.Tenant, read)
}

// costMonthIn runs both reads in tx, under whatever scope tx holds.
func costMonthIn(ctx context.Context, tx pgx.Tx, q CostMonthQuery) (CostMonth, error) {
	out := CostMonth{Parts: []CostPart{}, Coverage: []CostSourceDays{}}
	rows, err := tx.Query(ctx, costMonthParts, q.From, q.To, q.Tenant, q.Estate)
	if err != nil {
		return out, err
	}
	out.Parts, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (p CostPart, err error) {
		err = r.Scan(&p.Estate, &p.Source, &p.ProjectOrVendor, &p.Kind, &p.Origin,
			&p.Units, &p.USDMicros, &p.EURMicros, &p.ListValueMicros, &p.Days)
		return p, err
	})
	if err != nil {
		return out, err
	}
	var only []string // nil = every source (the estate)
	if !q.Estate {
		only = []string{}
		for _, p := range out.Parts {
			if !slices.Contains(only, p.Source) {
				only = append(only, p.Source)
			}
		}
	}
	coverTo := q.CoverTo
	if coverTo == "" {
		coverTo = q.To
	}
	rows, err = tx.Query(ctx, costMonthCoverage, q.From, coverTo, only)
	if err != nil {
		return out, err
	}
	out.Coverage, err = pgx.CollectRows(rows, func(r pgx.CollectableRow) (c CostSourceDays, err error) {
		err = r.Scan(&c.Source, &c.OK, &c.Partial, &c.Missing)
		return c, err
	})
	return out, err
}

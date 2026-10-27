package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"
)

// Postgres side of the month read's AI parts (cost_ai_paid.go). The burn
// rows are operator scope (rdb 0199's RLS): both reads run there, and only
// the shaped parts of the asked workspace leave the store.

// workspaceBurnDaysSQL is the burn per (day, vendor, work_tenant) of the UTC
// days [$1, $2), metered rows only, input + output + cache write: the minute
// rows of each day that still has any, else the day's rollup, so each day is
// counted once (fleetVendorDaysSQL's precedence, the price-per-token tokens).
const workspaceBurnDaysSQL = `WITH md AS (
	SELECT DISTINCT (minute_bucket AT TIME ZONE 'UTC')::date AS day FROM fleet_token_burn_events
	WHERE minute_bucket >= ($1::date)::timestamp AT TIME ZONE 'UTC' AND minute_bucket < ($2::date)::timestamp AT TIME ZONE 'UTC')
SELECT to_char((minute_bucket AT TIME ZONE 'UTC')::date, 'YYYY-MM-DD'), vendor, coalesce(work_tenant, ''),
	sum(tokens_in + tokens_out + cache_write)::bigint
FROM fleet_token_burn_events
WHERE is_metered AND minute_bucket >= ($1::date)::timestamp AT TIME ZONE 'UTC' AND minute_bucket < ($2::date)::timestamp AT TIME ZONE 'UTC'
GROUP BY 1, 2, 3
UNION ALL
SELECT to_char(d.day_bucket, 'YYYY-MM-DD'), d.vendor, coalesce(d.work_tenant, ''),
	sum(d.tokens_in + d.tokens_out + d.cache_write)::bigint
FROM fleet_token_burn_daily d
WHERE d.is_metered AND d.day_bucket >= $1::date AND d.day_bucket < $2::date
	AND NOT EXISTS (SELECT 1 FROM md WHERE md.day = d.day_bucket)
GROUP BY 1, 2, 3
ORDER BY 1, 2, 3`

// WorkspaceBurnDays is aiPaidSource on Postgres, in the operator scope.
func (s *Postgres) WorkspaceBurnDays(ctx context.Context, from, to time.Time) ([]WorkspaceBurnDay, error) {
	out := []WorkspaceBurnDay{}
	err := s.asOperatorQuery(ctx, workspaceBurnDaysSQL, []any{from.Format(time.DateOnly), to.Format(time.DateOnly)},
		func(rows pgx.Rows) error {
			var b WorkspaceBurnDay
			if err := rows.Scan(&b.Day, &b.Vendor, &b.Workspace, &b.Tokens); err != nil {
				return err
			}
			out = append(out, b)
			return nil
		})
	return out, err
}

// secondFXDaysSQL is quote $1's rate of every day of [$2, $3): that day's,
// else the last before it, an ECB row first on a tie (costMonthParts' rule).
const secondFXDaysSQL = `SELECT to_char(g.day, 'YYYY-MM-DD'), fx.rate::float8, to_char(fx.day, 'YYYY-MM-DD')
FROM generate_series($2::date, $3::date - 1, interval '1 day') g(day)
JOIN LATERAL (SELECT r.day, r.rate FROM fx_rates r WHERE r.quote = $1 AND r.day <= g.day::date
	ORDER BY r.day DESC, r.source = 'ECB' DESC LIMIT 1) fx ON true`

// secondFXDays is aiPaidSource on Postgres.
func (s *Postgres) secondFXDays(ctx context.Context, quote string, from, to time.Time) (map[string]fxDay, error) {
	out := map[string]fxDay{}
	if !to.After(from) {
		return out, nil
	}
	err := s.asOperatorQuery(ctx, secondFXDaysSQL, []any{quote, from.Format(time.DateOnly), to.Format(time.DateOnly)},
		func(rows pgx.Rows) error {
			var day string
			var fx fxDay
			if err := rows.Scan(&day, &fx.rate, &fx.day); err != nil {
				return err
			}
			out[day] = fx
			return nil
		})
	return out, err
}

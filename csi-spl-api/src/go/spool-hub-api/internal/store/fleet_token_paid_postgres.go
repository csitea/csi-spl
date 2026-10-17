package store

import (
	"context"
	"errors"
	"fmt"
	"time"

	"github.com/jackc/pgx/v5"

	uuid "github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// Postgres side of rdb 0205. Every statement runs in the operator scope: the
// rows are the instance's, no tenant (operatorCallers says who reaches it).

const fleetPaidCols = `id::text, vendor, kind, plan_label, quantity, amount::float8, currency,
	to_char(period_start, 'YYYY-MM-DD'), to_char(period_end, 'YYYY-MM-DD'), note, created_by, created_at, updated_at`

func scanFleetPaid(row pgx.Row) (FleetPaidItem, error) {
	var it FleetPaidItem
	err := row.Scan(&it.ID, &it.Vendor, &it.Kind, &it.PlanLabel, &it.Quantity, &it.Amount, &it.Currency,
		&it.PeriodStart, &it.PeriodEnd, &it.Note, &it.CreatedBy, &it.CreatedAt, &it.UpdatedAt)
	it.CreatedAt, it.UpdatedAt = it.CreatedAt.UTC(), it.UpdatedAt.UTC()
	return it, err
}

// ListPaidItems is FleetPaidStore on Postgres.
func (s *Postgres) ListPaidItems(ctx context.Context) ([]FleetPaidItem, error) {
	out := []FleetPaidItem{}
	err := s.asOperatorQuery(ctx, `SELECT `+fleetPaidCols+` FROM fleet_token_paid_items ORDER BY period_start, created_at, id`, nil,
		func(rows pgx.Rows) error {
			it, err := scanFleetPaid(rows)
			out = append(out, it)
			return err
		})
	return out, err
}

// CreatePaidItem is FleetPaidStore on Postgres.
func (s *Postgres) CreatePaidItem(ctx context.Context, it FleetPaidItem) (FleetPaidItem, error) {
	if why := CheckFleetPaidItem(it); why != "" {
		return FleetPaidItem{}, fmt.Errorf("fleet paid item: %s", why)
	}
	var out FleetPaidItem
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = scanFleetPaid(tx.QueryRow(ctx, `INSERT INTO fleet_token_paid_items (id, vendor, kind, plan_label, quantity,
			amount, currency, period_start, period_end, note, created_by)
			VALUES ($1, $2, $3, $4, $5, $6::numeric, $7, $8::date, $9::date, $10, $11) RETURNING `+fleetPaidCols,
			uuid.New(), it.Vendor, it.Kind, it.PlanLabel, it.Quantity, it.Amount, it.Currency, it.PeriodStart, it.PeriodEnd, it.Note, it.CreatedBy))
		return err
	})
	return out, err
}

// UpdatePaidItem is FleetPaidStore on Postgres.
func (s *Postgres) UpdatePaidItem(ctx context.Context, it FleetPaidItem) (FleetPaidItem, error) {
	if why := CheckFleetPaidItem(it); why != "" {
		return FleetPaidItem{}, fmt.Errorf("fleet paid item: %s", why)
	}
	if !uuidRe.MatchString(it.ID) {
		return FleetPaidItem{}, ErrNotFound
	}
	var out FleetPaidItem
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		var err error
		out, err = scanFleetPaid(tx.QueryRow(ctx, `UPDATE fleet_token_paid_items SET vendor = $2, kind = $3, plan_label = $4,
			quantity = $5, amount = $6::numeric, currency = $7, period_start = $8::date, period_end = $9::date, note = $10,
			updated_at = now() WHERE id = $1::uuid RETURNING `+fleetPaidCols,
			it.ID, it.Vendor, it.Kind, it.PlanLabel, it.Quantity, it.Amount, it.Currency, it.PeriodStart, it.PeriodEnd, it.Note))
		return err
	})
	if errors.Is(err, pgx.ErrNoRows) {
		return FleetPaidItem{}, ErrNotFound
	}
	return out, err
}

// DeletePaidItem is FleetPaidStore on Postgres.
func (s *Postgres) DeletePaidItem(ctx context.Context, id string) error {
	if !uuidRe.MatchString(id) {
		return ErrNotFound
	}
	return s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, `DELETE FROM fleet_token_paid_items WHERE id = $1::uuid`, id)
		if err == nil && tag.RowsAffected() == 0 {
			return ErrNotFound
		}
		return err
	})
}

// fleetVendorDaysSQL is the burn per (day, vendor) of [$1, $2): the minute
// rows of each day that still has any, else the day's rollup. The list cost
// sums the rows priced in USD only (model_prices are USD today).
const fleetVendorDaysSQL = `WITH md AS (
	SELECT DISTINCT (minute_bucket AT TIME ZONE 'UTC')::date AS day FROM fleet_token_burn_events
	WHERE minute_bucket >= $1 AND minute_bucket < $2)
SELECT (minute_bucket AT TIME ZONE 'UTC')::date, vendor, sum(tokens_in + tokens_out + cache_write)::bigint,
	sum(cache_read)::bigint, (coalesce(sum(cost_micros) FILTER (WHERE priced AND currency = 'USD'), 0) / 1e6)::float8
FROM fleet_token_burn_events WHERE is_metered AND minute_bucket >= $1 AND minute_bucket < $2 GROUP BY 1, 2
UNION ALL
SELECT d.day_bucket, d.vendor, sum(d.tokens_in + d.tokens_out + d.cache_write)::bigint,
	sum(d.cache_read)::bigint, (coalesce(sum(d.cost_micros) FILTER (WHERE d.currency = 'USD'), 0) / 1e6)::float8
FROM fleet_token_burn_daily d WHERE d.is_metered AND d.day_bucket >= $1::date AND d.day_bucket < $2::date
	AND NOT EXISTS (SELECT 1 FROM md WHERE md.day = d.day_bucket) GROUP BY 1, 2
ORDER BY 1, 2`

// FleetVendorDays is FleetPaidStore on Postgres.
func (s *Postgres) FleetVendorDays(ctx context.Context, from, to time.Time) ([]FleetVendorDay, error) {
	out := []FleetVendorDay{}
	err := s.asOperatorQuery(ctx, fleetVendorDaysSQL, []any{from.UTC(), to.UTC()}, func(rows pgx.Rows) error {
		var d FleetVendorDay
		if err := rows.Scan(&d.Day, &d.Vendor, &d.Tokens, &d.CacheRead, &d.ListCostUSD); err != nil {
			return err
		}
		d.Day = time.Date(d.Day.Year(), d.Day.Month(), d.Day.Day(), 0, 0, 0, 0, time.UTC)
		out = append(out, d)
		return nil
	})
	return out, err
}

// fleetPaidFXSQL is quote $1's rate on day $2, else the last before it, else
// the first after it; ECB before FED on a day both published.
const fleetPaidFXSQL = `SELECT rate::float8, to_char(day, 'YYYY-MM-DD') FROM (
	(SELECT day, rate, 0 AS pref FROM fx_rates WHERE quote = $1 AND day <= $2::date ORDER BY day DESC, source = 'ECB' DESC LIMIT 1)
	UNION ALL
	(SELECT day, rate, 1 AS pref FROM fx_rates WHERE quote = $1 AND day > $2::date ORDER BY day, source = 'ECB' DESC LIMIT 1)
) r ORDER BY pref LIMIT 1`

// FleetPaidFXRate is FleetPaidStore on Postgres.
func (s *Postgres) FleetPaidFXRate(ctx context.Context, quote, day string) (float64, string, bool, error) {
	var rate float64
	var at string
	found := false
	err := s.asOperatorQuery(ctx, fleetPaidFXSQL, []any{quote, day}, func(rows pgx.Rows) error {
		found = true
		return rows.Scan(&rate, &at)
	})
	return rate, at, found, err
}

var _ FleetPaidStore = (*Postgres)(nil)

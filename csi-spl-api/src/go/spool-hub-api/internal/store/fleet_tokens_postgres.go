package store

import (
	"context"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Postgres side of rdb 0199. Every statement runs in the operator scope: the
// rows are the instance's, no tenant (operatorCallers says who reaches it).

// fleetTokenPricesSQL is every price row of the push's models; the pricer
// picks the one in force at each sample's minute.
const fleetTokenPricesSQL = `SELECT provider, model, kind, micros_per_million, currency, valid_from
	FROM model_prices WHERE provider = ANY($1) AND model = ANY($2)`

// fleetTokenUpsert writes the push from parallel arrays in one statement. A
// re-sent minute overwrites its row: counts are the box's running total of
// the minute, never a delta. A package var so the idempotency test's control
// can drop the ON CONFLICT.
var fleetTokenUpsert = `INSERT INTO fleet_token_burn_events (box_tag, agent_id, vendor, model, minute_bucket,
	tokens_in, tokens_out, cache_read, cache_write, cost_micros, currency, priced, is_metered)
SELECT $1, s.agent, s.vendor, NULLIF(s.model, ''), s.minute, s.tin, s.tout, s.cr, s.cw, s.cost::numeric, s.cur, s.priced, s.metered
FROM unnest($2::text[], $3::text[], $4::text[], $5::timestamptz[], $6::bigint[], $7::bigint[], $8::bigint[], $9::bigint[],
	$10::text[], $11::text[], $12::bool[], $13::bool[])
	AS s(agent, vendor, model, minute, tin, tout, cr, cw, cost, cur, priced, metered)
ON CONFLICT (box_tag, agent_id, minute_bucket) DO UPDATE SET vendor = EXCLUDED.vendor, model = EXCLUDED.model,
	tokens_in = EXCLUDED.tokens_in, tokens_out = EXCLUDED.tokens_out, cache_read = EXCLUDED.cache_read,
	cache_write = EXCLUDED.cache_write, cost_micros = EXCLUDED.cost_micros, currency = EXCLUDED.currency,
	priced = EXCLUDED.priced, is_metered = EXCLUDED.is_metered, updated_at = now()`

// RecordSamples is FleetTokenStore on Postgres: the push's price rows, then
// one upsert, in one operator transaction.
func (s *Postgres) RecordSamples(ctx context.Context, box string, samples []wire.FleetTokenSample) (int, error) {
	n := len(samples)
	if n == 0 {
		return 0, nil
	}
	agent, vendor, model, cost, cur := make([]string, n), make([]string, n), make([]string, n), make([]string, n), make([]string, n)
	minute := make([]time.Time, n)
	tin, tout, cr, cw := make([]int64, n), make([]int64, n), make([]int64, n), make([]int64, n)
	priced, metered := make([]bool, n), make([]bool, n)
	var providers, models []string
	for _, x := range samples {
		if p := FleetTokenProvider(x.Vendor); p != "" && x.ModelName() != "" {
			providers, models = append(providers, p), append(models, fleetTokenModel(x.ModelName()))
		}
	}
	written := 0
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		var pricer fleetTokenPricer
		if len(providers) > 0 {
			rows, err := tx.Query(ctx, fleetTokenPricesSQL, providers, models)
			if err != nil {
				return err
			}
			for rows.Next() {
				var p fleetTokenPrice
				if err := rows.Scan(&p.provider, &p.model, &p.kind, &p.micros, &p.currency, &p.from); err != nil {
					rows.Close()
					return err
				}
				pricer = append(pricer, p)
			}
			rows.Close()
			if err := rows.Err(); err != nil {
				return err
			}
		}
		for i, x := range samples {
			agent[i], vendor[i], model[i], minute[i] = x.AgentID, x.Vendor, x.ModelName(), x.Minute.UTC()
			tin[i], tout[i], cr[i], cw[i], metered[i] = x.TokensIn, x.TokensOut, x.CacheRead, x.CacheWrite, x.IsMetered
			cost[i], cur[i], priced[i] = pricer.price(x)
		}
		tag, err := tx.Exec(ctx, fleetTokenUpsert, box, agent, vendor, model, minute, tin, tout, cr, cw, cost, cur, priced, metered)
		written = int(tag.RowsAffected())
		return err
	})
	return written, err
}

// ListBuckets takes the newest FleetTokenRowsMax rows of the window, then
// returns them oldest first.
func (s *Postgres) ListBuckets(ctx context.Context, since time.Time, vendor string) ([]FleetTokenBucket, error) {
	out := []FleetTokenBucket{}
	err := s.asOperatorQuery(ctx, `SELECT box_tag, agent_id, vendor, coalesce(model, ''), minute_bucket,
		tokens_in, tokens_out, cache_read, cache_write, cost_micros::float8, currency, priced, is_metered
		FROM fleet_token_burn_events WHERE minute_bucket >= $1 AND ($2 = '' OR vendor = $2)
		ORDER BY minute_bucket DESC, box_tag DESC, agent_id DESC LIMIT $3`, []any{since.UTC(), vendor, FleetTokenRowsMax},
		func(rows pgx.Rows) error {
			var b FleetTokenBucket
			if err := rows.Scan(&b.BoxTag, &b.AgentID, &b.Vendor, &b.Model, &b.Minute, &b.TokensIn, &b.TokensOut,
				&b.CacheRead, &b.CacheWrite, &b.CostMicros, &b.Currency, &b.Priced, &b.IsMetered); err != nil {
				return err
			}
			b.Minute = b.Minute.UTC()
			out = append(out, b)
			return nil
		})
	for i, j := 0, len(out)-1; i < j; i, j = i+1, j-1 {
		out[i], out[j] = out[j], out[i]
	}
	return out, err
}

// ListDays is FleetTokenStore on Postgres.
func (s *Postgres) ListDays(ctx context.Context, since time.Time) ([]FleetTokenDay, error) {
	out := []FleetTokenDay{}
	err := s.asOperatorQuery(ctx, `SELECT day_bucket, box_tag, agent_id, vendor, coalesce(model, ''), minutes,
		tokens_in, tokens_out, cache_read, cache_write, cost_micros::float8, currency, is_metered
		FROM fleet_token_burn_daily WHERE day_bucket >= $1::date ORDER BY day_bucket, box_tag, agent_id`,
		[]any{since.UTC().Format(time.DateOnly)},
		func(rows pgx.Rows) error {
			var d FleetTokenDay
			if err := rows.Scan(&d.Day, &d.BoxTag, &d.AgentID, &d.Vendor, &d.Model, &d.Minutes, &d.TokensIn, &d.TokensOut,
				&d.CacheRead, &d.CacheWrite, &d.CostMicros, &d.Currency, &d.IsMetered); err != nil {
				return err
			}
			d.Day = time.Date(d.Day.Year(), d.Day.Month(), d.Day.Day(), 0, 0, 0, 0, time.UTC)
			out = append(out, d)
			return nil
		})
	return out, err
}

// fleetTokenRollup rolls whole UTC days of minutes into the daily table: the
// minutes at or after $1 (yesterday and today, still moving) and before $2
// (the days the prune is about to drop). vendor and model are the day's
// latest minute's; currency a priced minute's when one is.
const fleetTokenRollup = `INSERT INTO fleet_token_burn_daily AS d (day_bucket, box_tag, agent_id, vendor, model, minutes,
	tokens_in, tokens_out, cache_read, cache_write, cost_micros, currency, is_metered, rolled_at)
SELECT (e.minute_bucket AT TIME ZONE 'UTC')::date, e.box_tag, e.agent_id,
	(array_agg(e.vendor ORDER BY e.minute_bucket DESC))[1], (array_agg(e.model ORDER BY e.minute_bucket DESC))[1],
	count(*), sum(e.tokens_in), sum(e.tokens_out), sum(e.cache_read), sum(e.cache_write), sum(e.cost_micros),
	coalesce(min(e.currency) FILTER (WHERE e.priced), min(e.currency)), bool_or(e.is_metered), now()
FROM fleet_token_burn_events e WHERE e.minute_bucket >= $1 OR e.minute_bucket < $2
GROUP BY 1, 2, 3
ON CONFLICT (day_bucket, box_tag, agent_id) DO UPDATE SET vendor = EXCLUDED.vendor, model = EXCLUDED.model,
	minutes = EXCLUDED.minutes, tokens_in = EXCLUDED.tokens_in, tokens_out = EXCLUDED.tokens_out,
	cache_read = EXCLUDED.cache_read, cache_write = EXCLUDED.cache_write, cost_micros = EXCLUDED.cost_micros,
	currency = EXCLUDED.currency, is_metered = EXCLUDED.is_metered, rolled_at = now()`

// PruneOldBuckets is FleetTokenStore on Postgres: rollup, then both
// deletes, in one operator transaction.
func (s *Postgres) PruneOldBuckets(ctx context.Context, now time.Time) (FleetTokenPrune, error) {
	minuteCut, dayCut, rollFrom := fleetTokenCuts(now)
	var res FleetTokenPrune
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, fleetTokenRollup, rollFrom, minuteCut)
		if err != nil {
			return err
		}
		res.RolledDays = int(tag.RowsAffected())
		if tag, err = tx.Exec(ctx, `DELETE FROM fleet_token_burn_events WHERE minute_bucket < $1`, minuteCut); err != nil {
			return err
		}
		res.PrunedMinutes = int(tag.RowsAffected())
		if tag, err = tx.Exec(ctx, `DELETE FROM fleet_token_burn_daily WHERE day_bucket < $1::date`, dayCut.Format(time.DateOnly)); err != nil {
			return err
		}
		res.PrunedDays = int(tag.RowsAffected())
		return nil
	})
	if err != nil {
		return FleetTokenPrune{}, err
	}
	return res, nil
}

var _ FleetTokenStore = (*Postgres)(nil)

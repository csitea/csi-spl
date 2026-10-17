package store

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Reprice of unpriced fleet token minutes (spec 140 T010, SPL-2405). A minute
// pushed while its model had no model_prices row was stored priced=false,
// cost 0. Once the row exists (SPL-2323: the dated-id strip, the
// mistral-large price), this prices those minutes ONCE, with the live
// pricer (fleetTokenPricer.price), so each gets exactly the cost a push of
// the same minute would get now. A priced row is never touched; nor is an
// unmetered one, another model's or one before from.

// FleetTokenRepriceModel is one model's line of a reprice run. CostMicros is
// the sum of the costs the run set (a dry run: would set), numeric(20,6) text.
type FleetTokenRepriceModel struct {
	Model          string `json:"model"`
	UnpricedBefore int    `json:"unpriced_before"`
	Priced         int    `json:"priced"`
	CostMicros     string `json:"cost_micros"`
	Currency       string `json:"currency"`
	UnpricedAfter  int    `json:"unpriced_after"`
}

// FleetTokenReprice is what one run did, per model in the order asked.
type FleetTokenReprice struct {
	DryRun     bool                     `json:"dry_run"`
	From       string                   `json:"from"`
	Models     []FleetTokenRepriceModel `json:"models"`
	RolledDays int                      `json:"rolled_days"`
}

// FleetTokenRepricer is the reprice half of the fleet token store (Memory,
// Postgres).
type FleetTokenRepricer interface {
	// RepriceUnpriced prices the metered, unpriced minutes of models (the
	// stored model names) at or after from, in one operator transaction; dry
	// rolls it back. Postgres then re-rolls the daily rows of every day at or
	// after from's day, as the retention pass does.
	RepriceUnpriced(ctx context.Context, models []string, from time.Time, dry bool) (FleetTokenReprice, error)
}

// fleetRepriceRow is one unpriced minute and the price it gets now.
type fleetRepriceRow struct {
	b              FleetTokenBucket
	cost, currency string
}

// sample is the row as the push that wrote it: what the pricer reads.
func (b FleetTokenBucket) sample() wire.FleetTokenSample {
	s := wire.FleetTokenSample{AgentID: b.AgentID, Vendor: b.Vendor, Minute: b.Minute, TokensIn: b.TokensIn,
		TokensOut: b.TokensOut, CacheRead: b.CacheRead, CacheWrite: b.CacheWrite, IsMetered: b.IsMetered}
	if b.Model != "" {
		m := b.Model
		s.Model = &m
	}
	return s
}

// repriceFold prices rows with pricer and sums them per model: before counts
// every row of the model, after the rows that still find no price.
func repriceFold(models []string, rows []FleetTokenBucket, pricer fleetTokenPricer) ([]fleetRepriceRow, []FleetTokenRepriceModel) {
	idx := map[string]int{}
	out := make([]FleetTokenRepriceModel, len(models))
	sums := make([]*big.Rat, len(models))
	for i, m := range models {
		idx[m], out[i], sums[i] = i, FleetTokenRepriceModel{Model: m}, new(big.Rat)
	}
	priced := []fleetRepriceRow{}
	for _, b := range rows {
		i, ok := idx[b.Model]
		if !ok {
			continue
		}
		out[i].UnpricedBefore++
		cost, cur, ok := pricer.price(b.sample())
		if !ok {
			out[i].UnpricedAfter++
			continue
		}
		c, _ := new(big.Rat).SetString(cost)
		sums[i].Add(sums[i], c)
		out[i].Priced++
		out[i].Currency = cur
		priced = append(priced, fleetRepriceRow{b: b, cost: cost, currency: cur})
	}
	for i := range out {
		out[i].CostMicros = sums[i].FloatString(6)
	}
	return priced, out
}

// repriceArgs refuses no model, an empty or repeated one, and no from.
func repriceArgs(models []string, from time.Time) error {
	if len(models) == 0 {
		return errors.New("reprice: no model named")
	}
	seen := map[string]bool{}
	for _, m := range models {
		if m == "" || seen[m] {
			return fmt.Errorf("reprice: model %q is empty or named twice", m)
		}
		seen[m] = true
	}
	if from.IsZero() {
		return errors.New("reprice: from is required")
	}
	return nil
}

// errRepriceDry rolls a dry run's transaction back.
var errRepriceDry = errors.New("reprice: dry run, rolled back")

// burnUnpricedSQL is the minutes a reprice may price, locked.
const burnUnpricedSQL = `SELECT box_tag, agent_id, vendor, coalesce(model, ''), minute_bucket,
	tokens_in, tokens_out, cache_read, cache_write
	FROM fleet_token_burn_events
	WHERE model = ANY($1) AND minute_bucket >= $2 AND is_metered AND NOT priced AND cost_micros = 0
	ORDER BY minute_bucket, box_tag, agent_id FOR UPDATE`

// burnRepriceUpdateSQL sets the new prices. A package var so the test's
// control can drop the WHERE's unpriced test; with it, a row priced
// meanwhile is never overwritten.
var burnRepriceUpdateSQL = `UPDATE fleet_token_burn_events e
	SET cost_micros = u.cost::numeric, currency = u.cur, priced = true, updated_at = now()
	FROM unnest($1::text[], $2::text[], $3::timestamptz[], $4::text[], $5::text[]) AS u(box, agent, minute, cost, cur)
	WHERE e.box_tag = u.box AND e.agent_id = u.agent AND e.minute_bucket = u.minute
	AND e.is_metered AND NOT e.priced AND e.cost_micros = 0`

// loadFleetTokenPricer reads every price row of the providers' models.
func loadFleetTokenPricer(ctx context.Context, tx pgx.Tx, providers, models []string) (fleetTokenPricer, error) {
	var pricer fleetTokenPricer
	rows, err := tx.Query(ctx, fleetTokenPricesSQL, providers, models)
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	for rows.Next() {
		var p fleetTokenPrice
		if err := rows.Scan(&p.provider, &p.model, &p.kind, &p.micros, &p.currency, &p.from); err != nil {
			return nil, err
		}
		pricer = append(pricer, p)
	}
	return pricer, rows.Err()
}

func readUnpriced(ctx context.Context, tx pgx.Tx, models []string, from time.Time) ([]FleetTokenBucket, error) {
	rows, err := tx.Query(ctx, burnUnpricedSQL, models, from.UTC())
	if err != nil {
		return nil, err
	}
	defer rows.Close()
	out := []FleetTokenBucket{}
	for rows.Next() {
		b := FleetTokenBucket{IsMetered: true}
		if err := rows.Scan(&b.BoxTag, &b.AgentID, &b.Vendor, &b.Model, &b.Minute, &b.TokensIn, &b.TokensOut,
			&b.CacheRead, &b.CacheWrite); err != nil {
			return nil, err
		}
		b.Minute = b.Minute.UTC()
		out = append(out, b)
	}
	return out, rows.Err()
}

// repriceProviders is the price rows' keys of rows, as RecordSamples reads them.
func repriceProviders(rows []FleetTokenBucket) (providers, models []string) {
	for _, b := range rows {
		if p := FleetTokenProvider(b.Vendor); p != "" && b.Model != "" {
			providers, models = append(providers, p), append(models, fleetTokenModel(b.Model))
		}
	}
	return providers, models
}

// writeReprice updates the priced rows and fails (rolls back) unless every
// one was still the unpriced row it was read as.
func writeReprice(ctx context.Context, tx pgx.Tx, priced []fleetRepriceRow) error {
	n := len(priced)
	box, agent, cost, cur := make([]string, n), make([]string, n), make([]string, n), make([]string, n)
	minute := make([]time.Time, n)
	for i, r := range priced {
		box[i], agent[i], minute[i], cost[i], cur[i] = r.b.BoxTag, r.b.AgentID, r.b.Minute, r.cost, r.currency
	}
	tag, err := tx.Exec(ctx, burnRepriceUpdateSQL, box, agent, minute, cost, cur)
	if err != nil {
		return err
	}
	if int(tag.RowsAffected()) != n {
		return fmt.Errorf("reprice: updated %d rows, priced %d: rolled back", tag.RowsAffected(), n)
	}
	return nil
}

// RepriceUnpriced is FleetTokenRepricer on Postgres.
func (s *Postgres) RepriceUnpriced(ctx context.Context, models []string, from time.Time, dry bool) (FleetTokenReprice, error) {
	res := FleetTokenReprice{DryRun: dry, From: from.UTC().Format(time.RFC3339)}
	if err := repriceArgs(models, from); err != nil {
		return res, err
	}
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		rows, err := readUnpriced(ctx, tx, models, from)
		if err != nil {
			return err
		}
		providers, ms := repriceProviders(rows)
		pricer, err := loadFleetTokenPricer(ctx, tx, providers, ms)
		if err != nil {
			return err
		}
		priced, per := repriceFold(models, rows, pricer)
		res.Models = per
		if err := writeReprice(ctx, tx, priced); err != nil {
			return err
		}
		if len(priced) > 0 {
			tag, err := tx.Exec(ctx, fleetTokenRollup, from.UTC().Truncate(24*time.Hour), time.Unix(0, 0).UTC())
			if err != nil {
				return err
			}
			res.RolledDays = int(tag.RowsAffected())
		}
		if dry {
			return errRepriceDry
		}
		return nil
	})
	if errors.Is(err, errRepriceDry) {
		err = nil
	}
	return res, err
}

// RepriceUnpriced is FleetTokenRepricer on Memory (no daily re-roll: the
// Memory retention pass re-rolls on its next run).
func (s *Memory) RepriceUnpriced(_ context.Context, models []string, from time.Time, dry bool) (FleetTokenReprice, error) {
	res := FleetTokenReprice{DryRun: dry, From: from.UTC().Format(time.RFC3339)}
	if err := repriceArgs(models, from); err != nil {
		return res, err
	}
	pricer := s.memFleetPricer()
	memFleetTokensMu.Lock()
	defer memFleetTokensMu.Unlock()
	rows := []FleetTokenBucket{}
	for _, b := range memFleetTokens[s] {
		if b.IsMetered && !b.Priced && b.CostMicros == 0 && !b.Minute.Before(from.UTC()) {
			rows = append(rows, b)
		}
	}
	sortFleetBuckets(rows)
	priced, per := repriceFold(models, rows, pricer)
	res.Models = per
	if dry {
		return res, nil
	}
	for _, r := range priced {
		c, _ := new(big.Rat).SetString(r.cost)
		f, _ := c.Float64()
		b := r.b
		b.CostMicros, b.Currency, b.Priced = f, r.currency, true
		memFleetTokens[s][fleetTokenKey(b.BoxTag, b.AgentID, b.Minute)] = b
	}
	return res, nil
}

var (
	_ FleetTokenRepricer = (*Memory)(nil)
	_ FleetTokenRepricer = (*Postgres)(nil)
)

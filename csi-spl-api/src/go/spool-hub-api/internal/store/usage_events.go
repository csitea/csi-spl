package store

import (
	"context"
	"errors"
	"fmt"
	"math/big"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
)

// The metering ledger (specs/121 section 7, T302) over rdb 0171's
// usage_events and model_prices. The hub writes one turn's rows once: a
// reported turn as one row per token kind, each with the unit cost of the
// price in force copied onto it, so an old balance re-prices the same after
// a price change; a turn the seat never reported as ONE "unmetered" row with
// no units, cost or currency. A reader of the ledger therefore sees a gap as
// a gap, never as zero tokens (TurnLedger.Metered).

// Usage kinds of rdb 0171 the metering path writes.
const (
	UsageKindIn         = "llm_tokens_in"
	UsageKindOut        = "llm_tokens_out"
	UsageKindCacheRead  = "llm_tokens_cache_read"
	UsageKindCacheWrite = "llm_tokens_cache_write"
	UsageKindUnmetered  = "unmetered"
	usageTurnIDMax      = 100
	usageCostDecimal    = 6 // numeric(20,6): micros per unit
)

// ErrNoPrice: a reported kind has no model_prices row in force at the turn's
// time. Nothing is written; the hub writes the turn unmetered instead, since
// a metered row without its cost cannot exist (rdb 0171's CHECK).
var ErrNoPrice = errors.New("store: no model price in force")

// TurnRef names one turn of a workspace: TurnID is the ledger's key (one
// row per (tenant, turn, kind)), ChannelID, AgentID and HumanID "" are NULL.
// At is the event time and the time the price is read at.
type TurnRef struct {
	TurnID    string
	ChannelID string
	AgentID   string
	HumanID   string
	At        time.Time
}

// TurnUsage is a reported turn: the model that ran it and its counts. In and
// Out are always written (a reported 0 is a measured 0); the cache kinds only
// when non-zero, so a model without a cache needs no cache price.
type TurnUsage struct {
	TurnRef
	Provider   string
	Model      string
	TokensIn   int64
	TokensOut  int64
	CacheRead  int64
	CacheWrite int64
}

// rows is the (kind, units) list MeterTurn writes, in a fixed order.
func (u TurnUsage) rows() [][2]any {
	r := [][2]any{{UsageKindIn, u.TokensIn}, {UsageKindOut, u.TokensOut}}
	if u.CacheRead > 0 {
		r = append(r, [2]any{UsageKindCacheRead, u.CacheRead})
	}
	if u.CacheWrite > 0 {
		r = append(r, [2]any{UsageKindCacheWrite, u.CacheWrite})
	}
	return r
}

// TurnLedger is one turn as the ledger holds it. Rows 0 = never written
// (pending); Unmetered = the seat never reported it. Tokens, CostMicros
// (exact decimal micros of Currency) and Currency are set only when the turn
// is Metered.
type TurnLedger struct {
	Rows       int
	Unmetered  bool
	Tokens     int64
	CostMicros string
	Currency   string
}

// Metered reports whether the turn's tokens and cost are known. A pending or
// unmetered turn is NOT metered: its zero Tokens is no measurement.
func (l TurnLedger) Metered() bool { return l.Rows > 0 && !l.Unmetered }

// UsageLedger is the store half of metering. Optional: a hub whose store
// lacks it meters nothing.
type UsageLedger interface {
	// MeterTurn writes a reported turn in one transaction. written 0 = the
	// turn already holds rows (a re-sent report is never a second charge).
	// ErrNoPrice: a kind has no price in force at At; nothing is written.
	MeterTurn(ctx context.Context, tenant string, u TurnUsage) (written int, err error)
	// UnmeteredTurn writes the turn's one unmetered row; 0 = it holds rows.
	UnmeteredTurn(ctx context.Context, tenant string, t TurnRef) (written int, err error)
	// TurnLedger reads one turn back.
	TurnLedger(ctx context.Context, tenant, turnID string) (TurnLedger, error)
}

var (
	_ UsageLedger = (*Memory)(nil)
	_ UsageLedger = (*Postgres)(nil)
)

// checkTurn is the Go side of rdb 0171's CHECKs on a turn's names.
func checkTurn(tenant string, t TurnRef) error {
	if err := checkTenant(tenant); err != nil {
		return err
	}
	if t.TurnID == "" || len(t.TurnID) > usageTurnIDMax {
		return fmt.Errorf("usage: turn_id must be 1..%d bytes", usageTurnIDMax)
	}
	if len(t.ChannelID) > 200 || len(t.AgentID) > 100 || len(t.HumanID) > 200 {
		return fmt.Errorf("usage: channel, agent or human id too long")
	}
	return nil
}

// checkTurnUsage adds the report's own shape.
func checkTurnUsage(tenant string, u TurnUsage) error {
	if err := checkTurn(tenant, u.TurnRef); err != nil {
		return err
	}
	if u.Provider == "" || u.Model == "" {
		return fmt.Errorf("usage: a token row names its provider and model")
	}
	for _, n := range []int64{u.TokensIn, u.TokensOut, u.CacheRead, u.CacheWrite} {
		if n < 0 {
			return fmt.Errorf("usage: a token count is negative")
		}
	}
	return nil
}

// ModelPrice is one model_prices row: the price of a million units of kind
// in micros of Currency, from ValidFrom on.
type ModelPrice struct {
	Provider         string
	Model            string
	Kind             string
	MicrosPerMillion int64
	Currency         string
	ValidFrom        time.Time
}

// unitCost is micros_per_million / 10^6 as numeric(20,6) text: exact.
func unitCost(microsPerMillion int64) string {
	return new(big.Rat).SetFrac64(microsPerMillion, 1_000_000).FloatString(usageCostDecimal)
}

// usageEvent is one Memory ledger row.
type usageEvent struct {
	tenant, turn, kind, currency string
	units                        int64
	unitCost                     string
}

// Memory side: maps beside the Memory struct, guarded by s.mu.
var (
	memUsage  = map[*Memory][]usageEvent{}
	memPrices = map[*Memory][]ModelPrice{}
)

// PutModelPrice adds a price row to a Memory store (tests; Postgres prices
// are the operator's, written by do_spl_model_prices_sync).
func (s *Memory) PutModelPrice(p ModelPrice) {
	s.mu.Lock()
	defer s.mu.Unlock()
	memPrices[s] = append(memPrices[s], p)
}

// memPrice is the price of (provider, model, kind) in force at at.
func (s *Memory) memPrice(provider, model, kind string, at time.Time) (ModelPrice, bool) {
	var best ModelPrice
	ok := false
	for _, p := range memPrices[s] {
		if p.Provider == provider && p.Model == model && p.Kind == kind && !p.ValidFrom.After(at) &&
			(!ok || p.ValidFrom.After(best.ValidFrom)) {
			best, ok = p, true
		}
	}
	return best, ok
}

func (s *Memory) turnHasRows(tenant, turn string) bool {
	return slices.ContainsFunc(memUsage[s], func(e usageEvent) bool { return e.tenant == tenant && e.turn == turn })
}

func (s *Memory) MeterTurn(_ context.Context, tenant string, u TurnUsage) (int, error) {
	if err := checkTurnUsage(tenant, u); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.turnHasRows(tenant, u.TurnID) {
		return 0, nil
	}
	var add []usageEvent
	for _, r := range u.rows() {
		kind, units := r[0].(string), r[1].(int64)
		p, ok := s.memPrice(u.Provider, u.Model, kind, u.At)
		if !ok {
			return 0, fmt.Errorf("%w: %s %s %s", ErrNoPrice, u.Provider, u.Model, kind)
		}
		add = append(add, usageEvent{tenant, u.TurnID, kind, p.Currency, units, unitCost(p.MicrosPerMillion)})
	}
	memUsage[s] = append(memUsage[s], add...)
	return len(add), nil
}

func (s *Memory) UnmeteredTurn(_ context.Context, tenant string, t TurnRef) (int, error) {
	if err := checkTurn(tenant, t); err != nil {
		return 0, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.turnHasRows(tenant, t.TurnID) {
		return 0, nil
	}
	memUsage[s] = append(memUsage[s], usageEvent{tenant: tenant, turn: t.TurnID, kind: UsageKindUnmetered})
	return 1, nil
}

func (s *Memory) TurnLedger(_ context.Context, tenant, turnID string) (TurnLedger, error) {
	if err := checkTenant(tenant); err != nil {
		return TurnLedger{}, err
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	var l TurnLedger
	cost := new(big.Rat)
	for _, e := range memUsage[s] {
		if e.tenant != tenant || e.turn != turnID {
			continue
		}
		l.Rows++
		if e.kind == UsageKindUnmetered {
			l.Unmetered = true
			continue
		}
		c, _ := new(big.Rat).SetString(e.unitCost)
		cost.Add(cost, c.Mul(c, new(big.Rat).SetInt64(e.units)))
		l.Tokens += e.units
		l.Currency = e.currency
	}
	if l.Metered() {
		l.CostMicros = cost.FloatString(usageCostDecimal)
	} else {
		l.Tokens, l.Currency = 0, ""
	}
	return l, nil
}

// Postgres side. One transaction per turn: a transaction-scoped advisory
// lock on (tenant, turn) orders two writers of the same turn, so a report
// and an unmetered row can never both land (the unique index is per kind).
const (
	usageTurnLockSQL = `SELECT pg_advisory_xact_lock(hashtextextended($1 || '/' || $2, 171))`
	usageTurnRowsSQL = `SELECT count(*) FROM usage_events WHERE tenant_id = $1 AND turn_id = $2`
	usagePriceSQL    = `SELECT micros_per_million, currency FROM model_prices
		WHERE provider = $1 AND model = $2 AND kind = $3 AND valid_from <= $4
		ORDER BY valid_from DESC LIMIT 1`
	// key_source (rdb 0174, spec 127 7.2): named on every row, never left to
	// a default; 'workspace' comes with the lease of spec 127 H2 / P1.
	usageInsertSQL = `INSERT INTO usage_events (tenant_id, channel_id, agent_id, human_id, turn_id, kind,
		provider, model, units, unit_cost_micros, currency, at, key_source)
		VALUES ($1, NULLIF($2, ''), NULLIF($3, ''), NULLIF($4, ''), $5, $6,
		NULLIF($7, ''), NULLIF($8, ''), $9, $10::text::numeric, $11, $12, 'hub')`
	usageTurnReadSQL = `SELECT count(*), bool_or(kind = 'unmetered'),
		coalesce(sum(units), 0)::bigint, coalesce(sum(units * unit_cost_micros), 0)::text, coalesce(min(currency), '')
		FROM usage_events WHERE tenant_id = $1 AND turn_id = $2`
)

// lockTurn takes the turn's lock and reports whether it already holds rows.
func lockTurn(ctx context.Context, tx pgx.Tx, tenant, turn string) (bool, error) {
	if _, err := tx.Exec(ctx, usageTurnLockSQL, tenant, turn); err != nil {
		return false, err
	}
	var n int
	err := tx.QueryRow(ctx, usageTurnRowsSQL, tenant, turn).Scan(&n)
	return n > 0, err
}

func (s *Postgres) MeterTurn(ctx context.Context, tenant string, u TurnUsage) (int, error) {
	if err := checkTurnUsage(tenant, u); err != nil {
		return 0, err
	}
	written := 0
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if has, err := lockTurn(ctx, tx, tenant, u.TurnID); err != nil || has {
			return err
		}
		for _, r := range u.rows() {
			kind, units := r[0].(string), r[1].(int64)
			var micros int64
			var cur string
			err := tx.QueryRow(ctx, usagePriceSQL, u.Provider, u.Model, kind, u.At.UTC()).Scan(&micros, &cur)
			if errors.Is(err, pgx.ErrNoRows) {
				return fmt.Errorf("%w: %s %s %s", ErrNoPrice, u.Provider, u.Model, kind)
			}
			if err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, usageInsertSQL, tenant, u.ChannelID, u.AgentID, u.HumanID, u.TurnID, kind,
				u.Provider, u.Model, units, unitCost(micros), cur, u.At.UTC()); err != nil {
				return err
			}
		}
		written = len(u.rows())
		return nil
	})
	if err != nil {
		return 0, err
	}
	return written, nil
}

func (s *Postgres) UnmeteredTurn(ctx context.Context, tenant string, t TurnRef) (int, error) {
	if err := checkTurn(tenant, t); err != nil {
		return 0, err
	}
	written := 0
	err := s.inTenant(ctx, tenant, func(tx pgx.Tx) error {
		if has, err := lockTurn(ctx, tx, tenant, t.TurnID); err != nil || has {
			return err
		}
		_, err := tx.Exec(ctx, usageInsertSQL, tenant, t.ChannelID, t.AgentID, t.HumanID, t.TurnID, UsageKindUnmetered,
			"", "", nil, nil, nil, t.At.UTC())
		if err == nil {
			written = 1
		}
		return err
	})
	return written, err
}

func (s *Postgres) TurnLedger(ctx context.Context, tenant, turnID string) (TurnLedger, error) {
	var l TurnLedger
	var unmetered *bool
	err := s.queryRowTenant(ctx, tenant, usageTurnReadSQL, []any{tenant, turnID},
		&l.Rows, &unmetered, &l.Tokens, &l.CostMicros, &l.Currency)
	if err != nil {
		return TurnLedger{}, err
	}
	l.Unmetered = unmetered != nil && *unmetered
	if !l.Metered() {
		l.Tokens, l.CostMicros, l.Currency = 0, "", ""
	}
	return l, nil
}

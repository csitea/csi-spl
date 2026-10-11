package store

import (
	"context"
	"errors"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 121 T302: the metering ledger on both drivers. A reported turn is
// priced at write time from the price in force; a turn the seat never
// reported is one unmetered row and is NEVER read as zero tokens; a re-sent
// report is no second charge; a kind without a price writes nothing.

// putPrice writes one model_prices row: Memory's test seam, or the operator
// scope on Postgres (the only scope that may write a price).
func putPrice(t *testing.T, s Store, p ModelPrice) {
	t.Helper()
	switch d := s.(type) {
	case *Memory:
		d.PutModelPrice(p)
	case *Postgres:
		ctx := context.Background()
		if err := d.asOperator(ctx, func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO model_prices (provider, model, kind, micros_per_million, currency, valid_from)
				VALUES ($1, $2, $3, $4, $5, $6)`, p.Provider, p.Model, p.Kind, p.MicrosPerMillion, p.Currency, p.ValidFrom)
			return err
		}); err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatalf("no price seam for %T", s)
	}
}

func TestUsageLedgerTurns(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			ul := s.(UsageLedger)
			tenant := newTenant(t, s)
			model := uid("model-") // model_prices is hub-wide: a model of this run only
			t0 := time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
			at := t0.Add(48 * time.Hour)
			for kind, micros := range map[string]int64{UsageKindIn: 3_000_000, UsageKindOut: 15_000_000, UsageKindCacheRead: 300_000} {
				putPrice(t, s, ModelPrice{"anthropic", model, kind, micros, "EUR", t0})
			}
			// A later price change after the turn: never applied to it.
			putPrice(t, s, ModelPrice{"anthropic", model, UsageKindIn, 9_000_000, "EUR", at.Add(time.Hour)})

			rep := TurnUsage{TurnRef: TurnRef{TurnID: uid("turn-"), ChannelID: "sales", AgentID: "c-925", At: at},
				Provider: "anthropic", Model: model, TokensIn: 1000, TokensOut: 200, CacheRead: 10_000}
			if n, err := ul.MeterTurn(ctx, tenant, rep); err != nil || n != 3 {
				t.Fatalf("MeterTurn = %d, %v; want 3 rows (in, out, cache read; no cache write)", n, err)
			}
			got, err := ul.TurnLedger(ctx, tenant, rep.TurnID)
			// 1000*3 + 200*15 + 10000*0.3 micros = 9000 micros, at the price in force at the turn.
			if err != nil || !got.Metered() || got.Tokens != 11_200 || got.CostMicros != "9000.000000" || got.Currency != "EUR" {
				t.Errorf("reported turn reads %+v (%v), want metered 11200 tokens, 9000.000000 EUR micros", got, err)
			}
			if n, err := ul.MeterTurn(ctx, tenant, rep); err != nil || n != 0 {
				t.Errorf("a re-sent report wrote %d rows (%v), want 0: never a second charge", n, err)
			}
			if n, err := ul.UnmeteredTurn(ctx, tenant, rep.TurnRef); err != nil || n != 0 {
				t.Errorf("unmetered after a report wrote %d rows (%v), want 0", n, err)
			}

			// The done test: a turn without a report is never read as zero.
			gap := TurnRef{TurnID: uid("turn-"), AgentID: "c-925", At: at}
			if n, err := ul.UnmeteredTurn(ctx, tenant, gap); err != nil || n != 1 {
				t.Fatalf("UnmeteredTurn = %d, %v; want 1", n, err)
			}
			g, err := ul.TurnLedger(ctx, tenant, gap.TurnID)
			if err != nil || g.Metered() || !g.Unmetered || g.Rows != 1 || g.CostMicros != "" {
				t.Errorf("an unreported turn reads %+v (%v), want unmetered, NOT metered, no cost", g, err)
			}
			if n, err := ul.MeterTurn(ctx, tenant, TurnUsage{TurnRef: gap, Provider: "anthropic", Model: model}); err != nil || n != 0 {
				t.Errorf("a late report over an unmetered turn wrote %d rows (%v), want 0", n, err)
			}
			if p, err := ul.TurnLedger(ctx, tenant, uid("turn-")); err != nil || p.Metered() || p.Rows != 0 {
				t.Errorf("a turn never written reads %+v (%v), want 0 rows, not metered", p, err)
			}

			// A reported 0 is a measured 0: metered, zero cost.
			zero := TurnUsage{TurnRef: TurnRef{TurnID: uid("turn-"), At: at}, Provider: "anthropic", Model: model}
			if n, err := ul.MeterTurn(ctx, tenant, zero); err != nil || n != 2 {
				t.Fatalf("zero report = %d, %v; want 2 rows", n, err)
			}
			if z, _ := ul.TurnLedger(ctx, tenant, zero.TurnID); !z.Metered() || z.Tokens != 0 || z.CostMicros != "0.000000" {
				t.Errorf("a reported zero reads %+v, want metered 0", z)
			}

			// A kind without a price: nothing written, ErrNoPrice.
			nop := rep
			nop.TurnID, nop.CacheWrite = uid("turn-"), 5
			if n, err := ul.MeterTurn(ctx, tenant, nop); !errors.Is(err, ErrNoPrice) || n != 0 {
				t.Errorf("no cache-write price: %d, %v; want 0, ErrNoPrice", n, err)
			}
			if l, _ := ul.TurnLedger(ctx, tenant, nop.TurnID); l.Rows != 0 {
				t.Errorf("a refused report left %d rows", l.Rows)
			}
			early := rep
			early.TurnID, early.At = uid("turn-"), t0.Add(-time.Hour)
			if _, err := ul.MeterTurn(ctx, tenant, early); !errors.Is(err, ErrNoPrice) {
				t.Errorf("a turn before any price: %v, want ErrNoPrice", err)
			}

			// Another workspace reads none of it.
			other := newTenant(t, s)
			if o, err := ul.TurnLedger(ctx, other, rep.TurnID); err != nil || o.Rows != 0 {
				t.Errorf("another workspace reads %+v (%v) of the turn", o, err)
			}
			if _, err := ul.UnmeteredTurn(ctx, "", gap); !errors.Is(err, ErrNoTenant) {
				t.Errorf("no tenant: %v, want ErrNoTenant", err)
			}
		})
	}
}

// TestUsageLedgerNaiveSumReadsZero is the control of the done test: the
// unmetered turn's rows summed the naive way (coalesce to 0) DO read as
// zero tokens, so TurnLedger.Metered is what keeps the gap visible.
func TestUsageLedgerNaiveSumReadsZero(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	tenant := newTenant(t, pg)
	gap := TurnRef{TurnID: uid("turn-"), At: time.Now()}
	if _, err := pg.UnmeteredTurn(ctx, tenant, gap); err != nil {
		t.Fatal(err)
	}
	var naive int64
	if err := pg.queryRowTenant(ctx, tenant, `SELECT coalesce(sum(units), 0)::bigint FROM usage_events
		WHERE tenant_id = $1 AND turn_id = $2`, []any{tenant, gap.TurnID}, &naive); err != nil || naive != 0 {
		t.Fatalf("CONTROL: the naive sum reads %d (%v), want 0", naive, err)
	}
	if l, err := pg.TurnLedger(ctx, tenant, gap.TurnID); err != nil || l.Metered() {
		t.Errorf("TurnLedger reads the gap as metered: %+v (%v)", l, err)
	}
}

// TestUsageInsertNamesKeySource (spec 127 7.2, C12): the hub's ledger insert
// names key_source itself, so it holds once rdb 0174's expand default is
// dropped. In one rolled-back transaction with the default dropped, the
// insert writes a 'hub' row; CONTROL: the insert as it was before rdb 0174
// (no key_source) is refused, 23502. And MeterTurn's rows read 'hub'.
func TestUsageInsertNamesKeySource(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a := newTenant(t, pg)
	const oldInsertSQL = `INSERT INTO usage_events (tenant_id, channel_id, agent_id, human_id, turn_id, kind,
		provider, model, units, unit_cost_micros, currency, at)
		VALUES ($1, NULLIF($2, ''), NULLIF($3, ''), NULLIF($4, ''), $5, $6,
		NULLIF($7, ''), NULLIF($8, ''), $9, $10::text::numeric, $11, $12)`
	at := time.Date(2026, 10, 11, 0, 0, 0, 0, time.UTC)
	insert := func(tx pgx.Tx, sql, turn string) error {
		sp, err := tx.Begin(ctx) // savepoint: the refused CONTROL must not abort the transaction
		if err != nil {
			return err
		}
		if _, err := sp.Exec(ctx, sql, a, "", "c-925", "", turn, UsageKindIn, "anthropic", "m", int64(5), "1", "EUR", at); err != nil {
			sp.Rollback(ctx) //nolint:errcheck
			return err
		}
		return sp.Commit(ctx)
	}
	err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `ALTER TABLE usage_events ALTER COLUMN key_source DROP DEFAULT`); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, pgScopeTenant, a); err != nil {
			return err
		}
		turn := uid("turn-")
		if err := insert(tx, usageInsertSQL, turn); err != nil {
			t.Errorf("usageInsertSQL without the default: %v", err)
		}
		var src string
		if err := tx.QueryRow(ctx, `SELECT key_source FROM usage_events WHERE tenant_id = $1 AND turn_id = $2`, a, turn).Scan(&src); err != nil || src != "hub" {
			t.Errorf("usageInsertSQL wrote key_source %q (%v), want hub", src, err)
		}
		if err := insert(tx, oldInsertSQL, uid("turn-")); pgCode(err) != "23502" {
			t.Errorf("CONTROL: the insert without key_source: %v, want 23502", err)
		}
		return errRollback
	})
	if !errors.Is(err, errRollback) {
		t.Fatal(err)
	}
	model := uid("model-")
	for _, kind := range []string{UsageKindIn, UsageKindOut} {
		putPrice(t, pg, ModelPrice{"anthropic", model, kind, 3_000_000, "EUR", at.Add(-time.Hour)})
	}
	turn := uid("turn-")
	if n, err := pg.MeterTurn(ctx, a, TurnUsage{TurnRef: TurnRef{TurnID: turn, At: at}, Provider: "anthropic", Model: model, TokensIn: 10}); err != nil || n != 2 {
		t.Fatalf("MeterTurn = %d, %v; want 2 (in, out)", n, err)
	}
	var hub int
	if err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FROM usage_events WHERE tenant_id = $1 AND turn_id = $2 AND key_source = 'hub'`, a, turn).Scan(&hub)
	}); err != nil || hub != 2 {
		t.Errorf("MeterTurn's rows read key_source hub %d time(s) (%v), want 2", hub, err)
	}
}

package store

import (
	"context"
	"fmt"
	"math"
	"regexp"
	"slices"
	"time"

	"github.com/jackc/pgx/v5"
)

// Daily exchange rates for the costs' second currency (SPL-2108, rdb 0200
// fx_rates). Owner HUM-10, t1 1b6f871f msg 44fef397: a personal second
// currency (default EUR) beside the USD the AI providers bill in, converted at
// the ECB rate for a European currency and the Federal Reserve's for any
// other. A row is how many units of Quote one USD bought on Day. The box
// action do_spl_fx_rates_fetch (csi-spl-orc) reads both banks and posts the
// rows to POST /v1/operator/fx/rates; the cost read (cost_read.go) converts
// each cost day at that day's rate, else the last one before it.

// DefaultSecondCurrency is the second currency of a person who never picked
// one (the owner's default).
const DefaultSecondCurrency = "EUR"

// FXSources are rdb 0200's fx_rates.source CHECK.
var FXSources = []string{"ECB", "FED"}

// FXRatesMax is the rows one post may carry (90 days of ~40 currencies, twice).
const FXRatesMax = 10000

var fxQuoteRe = regexp.MustCompile(`^[A-Z]{3}$`)

// IsCurrencyCode reports whether v is shaped like an ISO 4217 code.
func IsCurrencyCode(v string) bool { return fxQuoteRe.MatchString(v) }

// FXRate is one published rate: Rate units of Quote per USD on Day.
type FXRate struct {
	Day    string  `json:"day"`
	Quote  string  `json:"quote"`
	Rate   float64 `json:"rate"`
	Source string  `json:"source"`
}

// FX is the store half of the rates. Optional: the hub's routes answer as off
// on a store without it, and the second-currency setting is then checked for
// its shape only.
type FX interface {
	// PutFXRates UPSERTs checked rows (CheckFXRates) on (day, quote, source)
	// in one operator transaction; a re-post of the same rows changes
	// nothing but fetched_at. It answers the rows written.
	PutFXRates(ctx context.Context, rows []FXRate) (int, error)
	// FXCurrencies is every quote the store holds a rate for, sorted.
	FXCurrencies(ctx context.Context) ([]string, error)
}

var _ FX = (*Postgres)(nil)

// CheckFXRates names the first thing rows may not carry ("" = fine): the Go
// side of rdb 0200's CHECKs, so the route refuses before the transaction.
func CheckFXRates(rows []FXRate) string {
	if len(rows) == 0 {
		return "rows must hold at least one rate"
	}
	if len(rows) > FXRatesMax {
		return fmt.Sprintf("at most %d rates per post", FXRatesMax)
	}
	seen := make(map[[3]string]bool, len(rows))
	for i, r := range rows {
		day, err := time.Parse(time.DateOnly, r.Day)
		switch {
		case !costDayRe.MatchString(r.Day) || err != nil || day.Format(time.DateOnly) != r.Day:
			return fmt.Sprintf("row %d: day must be a UTC day YYYY-MM-DD", i)
		case !IsCurrencyCode(r.Quote) || r.Quote == "USD":
			return fmt.Sprintf("row %d: quote must be an ISO 4217 code other than USD", i)
		case math.IsNaN(r.Rate) || math.IsInf(r.Rate, 0) || r.Rate <= 0 || r.Rate > 1e9:
			return fmt.Sprintf("row %d: rate must be a positive number of quote units per USD", i)
		case !slices.Contains(FXSources, r.Source):
			return fmt.Sprintf("row %d: source must be ECB or FED", i)
		}
		k := [3]string{r.Day, r.Quote, r.Source}
		if seen[k] {
			return fmt.Sprintf("row %d: a second rate for %s %s %s", i, r.Day, r.Quote, r.Source)
		}
		seen[k] = true
	}
	return ""
}

const fxRatesUpsert = `INSERT INTO fx_rates (day, quote, rate, source)
SELECT r.day, r.quote, r.rate, r.source
FROM unnest($1::date[], $2::text[], $3::numeric[], $4::text[]) AS r(day, quote, rate, source)
ON CONFLICT (day, quote, source) DO UPDATE SET rate = EXCLUDED.rate, fetched_at = now()`

// PutFXRates is FX on Postgres (see the interface).
func (s *Postgres) PutFXRates(ctx context.Context, rows []FXRate) (int, error) {
	if why := CheckFXRates(rows); why != "" {
		return 0, fmt.Errorf("fx rates: %s", why)
	}
	n := len(rows)
	day, quote, src := make([]string, n), make([]string, n), make([]string, n)
	rate := make([]float64, n)
	for i, r := range rows {
		day[i], quote[i], rate[i], src[i] = r.Day, r.Quote, r.Rate, r.Source
	}
	var written int
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		tag, err := tx.Exec(ctx, fxRatesUpsert, day, quote, rate, src)
		written = int(tag.RowsAffected())
		return err
	})
	return written, err
}

// FXCurrencies is FX on Postgres (see the interface).
func (s *Postgres) FXCurrencies(ctx context.Context) ([]string, error) {
	out := []string{}
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		rows, err := tx.Query(ctx, `SELECT DISTINCT quote FROM fx_rates ORDER BY 1`)
		if err != nil {
			return err
		}
		out, err = pgx.CollectRows(rows, pgx.RowTo[string])
		return err
	})
	return out, err
}

// FXCurrencies lets the auth package check a second currency against the
// rates the store holds; ok false = the store keeps none (shape check only).
func (a AuthHooks) FXCurrencies(ctx context.Context) ([]string, bool, error) {
	fx, ok := a.H.(FX)
	if !ok {
		return nil, false, nil
	}
	cs, err := fx.FXCurrencies(ctx)
	return cs, true, err
}

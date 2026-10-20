package store

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"slices"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// SPL-2108: the second currency of the cost report. Rates are hub-wide (rdb
// 0200), shared by every test on the database, so each test converts to a
// made-up quote of its own (fxTestQuote) in a month of its own (costTestMonth).

var fxQuotesTaken sync.Map

// fxTestQuote is a three-letter code no other test of this run uses; the
// leading Q keeps it off every real ISO 4217 code the fetch writes. The map
// only knows this process: hub-pg.tst.sh runs the store tests as SEQUENTIAL
// group processes on ONE database (store-pg-groups.inc.sh), so a quote an
// earlier group wrote rows under is also taken (run 39510389592: group b's
// TestPutFXRates drew a group a quote and counted 2 + 3 = 5 rows).
func fxTestQuote(t *testing.T, pg *Postgres) string {
	t.Helper()
	for {
		n, err := rand.Int(rand.Reader, big.NewInt(26*26))
		if err != nil {
			t.Fatal(err)
		}
		q := fmt.Sprintf("Q%c%c", 'A'+rune(n.Int64()/26), 'A'+rune(n.Int64()%26))
		if _, taken := fxQuotesTaken.LoadOrStore(q, true); taken {
			continue
		}
		var used bool
		if err := pg.asOperator(context.Background(), func(tx pgx.Tx) error {
			return tx.QueryRow(context.Background(), `SELECT EXISTS (SELECT 1 FROM fx_rates WHERE quote = $1)`, q).Scan(&used)
		}); err != nil {
			t.Fatal(err)
		}
		if !used {
			return q
		}
	}
}

// fxFriday is the second Friday of the month that starts on from.
func fxFriday(t *testing.T, from string) int {
	t.Helper()
	d, err := time.Parse(time.DateOnly, from)
	if err != nil {
		t.Fatal(err)
	}
	return 8 + (int(time.Friday)-int(d.Weekday())+7)%7
}

func TestCheckFXRates(t *testing.T) {
	ok := FXRate{Day: "2026-10-09", Quote: "EUR", Rate: 0.8934, Source: "ECB"}
	if why := CheckFXRates([]FXRate{ok}); why != "" {
		t.Fatalf("a good row refused: %s", why)
	}
	for name, bad := range map[string]FXRate{
		"day":    {Day: "2026-02-30", Quote: "EUR", Rate: 1, Source: "ECB"},
		"quote":  {Day: "2026-10-09", Quote: "eur", Rate: 1, Source: "ECB"},
		"usd":    {Day: "2026-10-09", Quote: "USD", Rate: 1, Source: "FED"},
		"rate":   {Day: "2026-10-09", Quote: "JPY", Rate: 0, Source: "FED"},
		"source": {Day: "2026-10-09", Quote: "JPY", Rate: 150, Source: "BOJ"},
	} {
		if CheckFXRates([]FXRate{bad}) == "" {
			t.Errorf("%s: %+v accepted", name, bad)
		}
	}
	if CheckFXRates(nil) == "" || CheckFXRates([]FXRate{ok, ok}) == "" {
		t.Error("an empty post or a duplicate (day, quote, source) was accepted")
	}
}

// TestPutFXRates: an UPSERT on (day, quote, source): a re-post writes the same
// row again (no duplicate), a changed rate replaces it; FXCurrencies lists the
// quote; a tenant scope reads the rates but cannot write one (rdb 0200 RLS).
func TestPutFXRates(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	q := fxTestQuote(t, pg)
	rows := []FXRate{{Day: "2003-04-04", Quote: q, Rate: 0.9, Source: "FED"}, {Day: "2003-04-07", Quote: q, Rate: 0.8, Source: "FED"}}
	for i := 0; i < 2; i++ {
		if n, err := pg.PutFXRates(ctx, rows); err != nil || n != 2 {
			t.Fatalf("post %d: %d, %v", i, n, err)
		}
	}
	rows[0].Rate = 0.95
	if _, err := pg.PutFXRates(ctx, rows[:1]); err != nil {
		t.Fatal(err)
	}
	var n int
	var rate float64
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*), max(rate) FILTER (WHERE day = '2003-04-04')::float8 FROM fx_rates WHERE quote = $1`, q).Scan(&n, &rate)
	}); err != nil {
		t.Fatal(err)
	}
	if n != 2 || rate != 0.95 {
		t.Fatalf("after re-posts: %d rows, rate %v; want 2 rows, the 04-04 rate 0.95", n, rate)
	}
	cs, err := pg.FXCurrencies(ctx)
	if err != nil || !slices.Contains(cs, q) {
		t.Fatalf("FXCurrencies %v, %v: want %s in it", cs, err, q)
	}
	a := newTenant(t, pg)
	if err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		return tx.QueryRow(ctx, `SELECT count(*) FROM fx_rates WHERE quote = $1`, q).Scan(&n)
	}); err != nil || n != 2 {
		t.Fatalf("a tenant scope reads %d rates, %v; want 2", n, err)
	}
	err = pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO fx_rates (day, quote, rate, source) VALUES ('2003-04-08', $1, 1, 'FED')`, q)
		return err
	})
	if err == nil || !strings.Contains(err.Error(), "row-level security") {
		t.Fatalf("a tenant scope wrote a rate: %v", err)
	}
}

// fxCheck is the second-currency assertion of TestCostMonthReadSecondCurrency
// (the red control runs it against a read with the conversion removed).
func fxCheck(m map[string]CostPart, q string, fri int, day func(int) string) error {
	week := m["false/hand/week-"+q+"/invoice"]
	mon := m["false/hand/mon-"+q+"/invoice"]
	early := m["false/hand/early-"+q+"/invoice"]
	switch {
	case week.SecondMicros == nil || *week.SecondMicros != 2_700_000:
		return fmt.Errorf("Fri 1.00 + Sat 2.00 USD at Friday's 0.9: second_micros %v, want 2700000", ptrStr(week.SecondMicros))
	case week.FXRate == nil || *week.FXRate != 0.9 || week.FXRateDay == nil || *week.FXRateDay != day(fri) ||
		week.FXRateFirstDay == nil || *week.FXRateFirstDay != day(fri):
		return fmt.Errorf("the Saturday falls back to Friday %s: rate %v day %v first %v", day(fri),
			ptrStr(week.FXRate), ptrStr(week.FXRateDay), ptrStr(week.FXRateFirstDay))
	case week.USDMicros != 3_000_000:
		return fmt.Errorf("USD changed: %d", week.USDMicros)
	case mon.SecondMicros == nil || *mon.SecondMicros != 2_400_000 || mon.FXRate == nil || *mon.FXRate != 0.8 ||
		mon.FXRateDay == nil || *mon.FXRateDay != day(fri+3):
		return fmt.Errorf("Monday 3.00 USD at Monday's ECB 0.8 (not the FED 0.7 of the same day): %v at %v on %v",
			ptrStr(mon.SecondMicros), ptrStr(mon.FXRate), ptrStr(mon.FXRateDay))
	case early.SecondMicros != nil || early.FXRate != nil || early.FXRateDay != nil || early.FXRateFirstDay != nil:
		return fmt.Errorf("a part with a day before every rate must convert to null, got %v at %v",
			ptrStr(early.SecondMicros), ptrStr(early.FXRate))
	}
	return nil
}

func ptrStr[T any](p *T) string {
	if p == nil {
		return "null"
	}
	return fmt.Sprint(*p)
}

// TestCostMonthReadSecondCurrency: under the workspace's own (tenant) scope,
// each cost day converts at its day's rate, a weekend day at the Friday
// before it, an ECB row wins a tie with a FED row of the same day, and a part
// with any day before every rate is null (never a guess). Red control: the
// same read with the conversion dropped fails the assertion.
func TestCostMonthReadSecondCurrency(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	from, to, day := costTestMonth(t)
	q := fxTestQuote(t, pg)
	a := newTenant(t, pg)
	fri := fxFriday(t, from)
	if _, err := pg.PutFXRates(ctx, []FXRate{
		{Day: day(fri), Quote: q, Rate: 0.9, Source: "FED"},
		{Day: day(fri + 3), Quote: q, Rate: 0.7, Source: "FED"},
		{Day: day(fri + 3), Quote: q, Rate: 0.8, Source: "ECB"},
	}); err != nil {
		t.Fatal(err)
	}
	costSeed(t, pg, a, day(fri), "hand", "week-"+q, "invoice", "hand", 0, 1_000_000, 0)
	costSeed(t, pg, a, day(fri+1), "hand", "week-"+q, "invoice", "hand", 0, 2_000_000, 0)
	costSeed(t, pg, a, day(fri+3), "hand", "mon-"+q, "invoice", "hand", 0, 3_000_000, 0)
	costSeed(t, pg, a, day(1), "hand", "early-"+q, "invoice", "hand", 0, 4_000_000, 0)
	costSeed(t, pg, a, day(fri), "hand", "early-"+q, "invoice", "hand", 0, 5_000_000, 0)

	read := func() map[string]CostPart {
		got, err := pg.CostMonthRead(ctx, CostMonthQuery{Tenant: a, From: from, To: to, Currency: q})
		if err != nil {
			t.Fatal(err)
		}
		return partsBy(got.Parts)
	}
	if err := fxCheck(read(), q, fri, day); err != nil {
		t.Fatal(err)
	}

	// Red control: drop the conversion (every line at rate 1) and the
	// assertion must fail.
	saved := costMonthParts
	t.Cleanup(func() { costMonthParts = saved })
	costMonthParts = strings.Replace(saved, "sum(c.usd_micros * fx.rate)", "sum(c.usd_micros)", 1)
	if costMonthParts == saved {
		t.Fatal("control: the conversion was not found in costMonthParts")
	}
	if err := fxCheck(read(), q, fri, day); err == nil {
		t.Fatal("control: with the conversion removed the second-currency assertion still passed")
	}
	costMonthParts = saved

	if _, err := pg.CostMonthRead(ctx, CostMonthQuery{Tenant: a, From: from, To: to, Currency: "eur"}); err == nil ||
		errors.Is(err, context.Canceled) {
		t.Fatalf("a lower-case currency was read: %v", err)
	}
}

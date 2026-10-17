package store

import (
	"context"
	"errors"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"

	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

func paidItem(by, vendor, kind string, qty int, amount float64, cur, start, end string) FleetPaidItem {
	return FleetPaidItem{Vendor: vendor, Kind: kind, PlanLabel: vendor + " " + kind, Quantity: qty, Amount: amount,
		Currency: cur, PeriodStart: start, PeriodEnd: end, CreatedBy: by}
}

// SPL-2342: create, list, update (created_by and created_at kept), delete;
// an unknown id is ErrNotFound; a bad item never reaches the table. Memory
// and Postgres.
func TestFleetPaidStoreCRUD(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			fp, ok := st.(FleetPaidStore)
			if !ok {
				t.Fatalf("%s keeps no paid items", name)
			}
			by := uid("op-")
			it, err := fp.CreatePaidItem(ctx, paidItem(by, "claude", "subscription", 3, 200, "USD", "2026-10-01", "2026-11-01"))
			if err != nil || !uuidRe.MatchString(it.ID) || it.CreatedBy != by || it.Quantity != 3 || it.Amount != 200 || it.PeriodEnd != "2026-11-01" {
				t.Fatalf("create: %+v %v", it, err)
			}
			if _, err := fp.CreatePaidItem(ctx, paidItem(by, "claude", "topup", 1, 250, "USD", "2026-10-05", "2026-10-05")); err == nil {
				t.Fatal("an item whose end is not after its start was stored")
			}
			mine := func() []FleetPaidItem {
				all, err := fp.ListPaidItems(ctx)
				if err != nil {
					t.Fatal(err)
				}
				var out []FleetPaidItem
				for _, x := range all {
					if x.CreatedBy == by {
						out = append(out, x)
					}
				}
				return out
			}
			if got := mine(); len(got) != 1 || got[0].ID != it.ID {
				t.Fatalf("list: %+v", got)
			}
			ch := it
			ch.Amount, ch.Note, ch.CreatedBy = 180.5, "price change", "someone-else"
			up, err := fp.UpdatePaidItem(ctx, ch)
			if err != nil || up.Amount != 180.5 || up.Note != "price change" || up.CreatedBy != by || !up.CreatedAt.Equal(it.CreatedAt) {
				t.Fatalf("update: %+v %v (created %v)", up, err, it.CreatedAt)
			}
			ch.ID = "00000000-0000-4000-8000-000000000000"
			if _, err := fp.UpdatePaidItem(ctx, ch); !errors.Is(err, ErrNotFound) {
				t.Fatalf("update of an unknown id: %v, want ErrNotFound", err)
			}
			if err := fp.DeletePaidItem(ctx, it.ID); err != nil {
				t.Fatal(err)
			}
			if err := fp.DeletePaidItem(ctx, it.ID); !errors.Is(err, ErrNotFound) {
				t.Fatalf("second delete: %v, want ErrNotFound", err)
			}
			if got := mine(); len(got) != 0 {
				t.Fatalf("after delete: %+v", got)
			}
		})
	}
}

// putFleetDay adds one fleet_token_burn_daily row to st.
func putFleetDay(t *testing.T, st Store, d FleetTokenDay) {
	t.Helper()
	switch s := st.(type) {
	case *Memory:
		memFleetTokensMu.Lock()
		if memFleetDays[s] == nil {
			memFleetDays[s] = map[[3]string]FleetTokenDay{}
		}
		memFleetDays[s][[3]string{d.Day.Format(time.DateOnly), d.BoxTag, d.AgentID}] = d
		memFleetTokensMu.Unlock()
	case *Postgres:
		if _, err := s.asOperator2(context.Background(), `INSERT INTO fleet_token_burn_daily (day_bucket, box_tag, agent_id, vendor,
			minutes, tokens_in, tokens_out, cache_read, cache_write, cost_micros, currency, is_metered)
			VALUES ($1::date, $2, $3, $4, 1, $5, $6, $7, $8, $9, 'USD', true)`, d.Day.Format(time.DateOnly), d.BoxTag, d.AgentID,
			d.Vendor, d.TokensIn, d.TokensOut, d.CacheRead, d.CacheWrite, d.CostMicros); err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatalf("no daily seam for %T", st)
	}
}

// SPL-2342: the burn per (day, vendor). A day still in the minute table is
// read from its minutes (its stale rollup ignored); an older day from its
// rollup; unmetered rows add nothing; cache reads stand apart from the
// divided tokens. A random day of 2005..2018: the Postgres tables are shared.
func TestFleetVendorDays(t *testing.T) {
	ctx := context.Background()
	n, _ := strconv.ParseUint(uid("")[:4], 16, 32) // uid is crypto-random
	dayA := time.Date(2005, 1, 1, 0, 0, 0, 0, time.UTC).AddDate(0, 0, int(n%5000))
	dayB := dayA.Add(24 * time.Hour)
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ft, fp := st.(FleetTokenStore), st.(FleetPaidStore)
			box := strings.ToLower(uid("v"))
			if _, err := ft.RecordSamples(ctx, box, []wire.FleetTokenSample{
				fleetSample("c-1", "claude", "no-such-model", dayA.Add(10*time.Minute), 100, 10, 1000, 5),
				fleetSample("c-1", "claude", "no-such-model", dayA.Add(11*time.Minute), 200, 20, 0, 0),
				fleetSample("m-1", "mistral", "", dayA.Add(12*time.Minute), 50, 0, 0, 0),
				{AgentID: "a-1", Vendor: "agy", Minute: dayA.Add(12 * time.Minute)},
			}); err != nil {
				t.Fatal(err)
			}
			putFleetDay(t, st, FleetTokenDay{Day: dayA, BoxTag: box, AgentID: "c-1", Vendor: "claude", TokensIn: 999999, Currency: "USD", IsMetered: true})
			putFleetDay(t, st, FleetTokenDay{Day: dayB, BoxTag: box, AgentID: "c-1", Vendor: "claude", TokensIn: 7, TokensOut: 3, CacheRead: 11, CostMicros: 2_000_000, Currency: "USD", IsMetered: true})
			got, err := fp.FleetVendorDays(ctx, dayA, dayB.Add(24*time.Hour))
			if err != nil {
				t.Fatal(err)
			}
			want := []FleetVendorDay{
				{Day: dayA, Vendor: "claude", Tokens: 335, CacheRead: 1000},
				{Day: dayA, Vendor: "mistral", Tokens: 50},
				{Day: dayB, Vendor: "claude", Tokens: 10, CacheRead: 11, ListCostUSD: 2},
			}
			if len(got) != len(want) {
				t.Fatalf("days %+v, want %+v", got, want)
			}
			for i := range want {
				if !got[i].Day.Equal(want[i].Day) || got[i].Vendor != want[i].Vendor || got[i].Tokens != want[i].Tokens ||
					got[i].CacheRead != want[i].CacheRead || got[i].ListCostUSD != want[i].ListCostUSD {
					t.Errorf("row %d: %+v, want %+v", i, got[i], want[i])
				}
			}
		})
	}
}

// SPL-2342: a paid item's rate is its first day's, else the last before it,
// else the first after it; ECB before FED on one day. Postgres only (the
// Memory store keeps no exchange rates).
func TestFleetPaidFXRate(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	// fxTestQuote, never a literal: TestPutFXRates counts its quote's rows, and a
	// literal from the same Q.. pool collided with it on CI (run 39039744142).
	q, none := fxTestQuote(t), fxTestQuote(t)
	if _, err := pg.PutFXRates(ctx, []FXRate{{Day: "2001-01-10", Quote: q, Rate: 2, Source: "FED"},
		{Day: "2001-01-20", Quote: q, Rate: 3, Source: "ECB"}, {Day: "2001-01-20", Quote: q, Rate: 4, Source: "FED"}}); err != nil {
		t.Fatal(err)
	}
	for day, want := range map[string]struct {
		rate float64
		at   string
	}{"2001-01-15": {2, "2001-01-10"}, "2001-01-20": {3, "2001-01-20"}, "2001-02-01": {3, "2001-01-20"}, "2000-12-01": {2, "2001-01-10"}} {
		if r, at, ok, err := pg.FleetPaidFXRate(ctx, q, day); err != nil || !ok || r != want.rate || at != want.at {
			t.Errorf("%s: %v %s %v %v, want %v %s", day, r, at, ok, err, want.rate, want.at)
		}
	}
	if _, _, ok, err := pg.FleetPaidFXRate(ctx, none, "2001-01-15"); ok || err != nil {
		t.Fatalf("a quote with no rate: ok %v %v, want false", ok, err)
	}
}

// SPL-2342: operator scope only, the rdb 0199 pattern: no scope and a
// workspace scope read nothing and write nothing.
func TestFleetPaidRLS(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	it, err := pg.CreatePaidItem(ctx, paidItem(uid("op-"), "agy", "subscription", 1, 20, "USD", "2026-10-01", "2026-11-01"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { pg.DeletePaidItem(ctx, it.ID) }) //nolint:errcheck
	tenant := newTenant(t, pg)
	for scope, run := range map[string]func(func(pgx.Tx) error) error{
		"none":      func(fn func(pgx.Tx) error) error { return pgx.BeginFunc(ctx, pg.pool, fn) },
		"workspace": func(fn func(pgx.Tx) error) error { return pg.inTenant(ctx, tenant, fn) },
	} {
		var n int
		if err := run(func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM fleet_token_paid_items`).Scan(&n)
		}); err != nil || n != 0 {
			t.Errorf("%s scope reads %d paid items (%v), want 0", scope, n, err)
		}
		err := run(func(tx pgx.Tx) error {
			_, err := tx.Exec(ctx, `INSERT INTO fleet_token_paid_items (id, vendor, kind, plan_label, amount, currency, period_start, period_end, created_by)
				VALUES (gen_random_uuid(), 'agy', 'topup', 'x', 1, 'USD', '2026-10-01', '2026-10-02', 'x')`)
			return err
		})
		if err == nil || !strings.Contains(err.Error(), "row-level security") {
			t.Errorf("%s scope insert: %v, want the RLS refusal", scope, err)
		}
	}
	if n, err := pg.asOperator2(ctx, `SELECT 1 FROM fleet_token_paid_items WHERE id = $1::uuid`, it.ID); err != nil || n != 1 {
		t.Fatalf("CONTROL: the operator scope reads the row: %d %v", n, err)
	}
}

// SPL-2342, the effective-price math over September 2026 (30 days):
//   - mistral: prepaid 6 months, 594 EUR for 2026-07-01..2027-01-01 (184
//     days) at 0.9 EUR per USD: 594/184/0.9 USD a day, 30 of them = 107.6087
//     USD over 10M tokens = 10.7609 USD per M tokens;
//   - claude: 3 x 200 USD for the 30 days (600) plus a 250 USD top-up for
//     09-16..10-16, half of it in range (125): 725 USD over 100M tokens =
//     7.25; its 900M cache reads are shown, never divided in (a math that
//     divided them in reads 0.725); list 1500 USD = 15 per M; an August
//     item adds nothing;
//   - agy: 20 USD a month and no tokens: not metered, 0.6667 a day;
//   - grok: no item, list price only;
//   - qwen: a GBP item with no rate: no_fx_rate, no sum.
func TestFleetPaidEffective(t *testing.T) {
	from, to := time.Date(2026, 9, 1, 0, 0, 0, 0, time.UTC), time.Date(2026, 10, 1, 0, 0, 0, 0, time.UTC)
	items := []FleetPaidItem{
		paidItem("op", "mistral", "subscription", 1, 594, "EUR", "2026-07-01", "2027-01-01"),
		paidItem("op", "claude", "subscription", 3, 200, "USD", "2026-09-01", "2026-10-01"),
		paidItem("op", "claude", "topup", 1, 250, "USD", "2026-09-16", "2026-10-16"),
		paidItem("op", "claude", "subscription", 3, 200, "USD", "2026-08-01", "2026-09-01"),
		paidItem("op", "agy", "subscription", 1, 20, "USD", "2026-09-01", "2026-10-01"),
		paidItem("op", "qwen", "topup", 1, 10, "GBP", "2026-09-01", "2026-10-01"),
	}
	d1, d2 := from, from.AddDate(0, 0, 20)
	days := []FleetVendorDay{
		{Day: d1, Vendor: "claude", Tokens: 60_000_000, CacheRead: 500_000_000, ListCostUSD: 900},
		{Day: d2, Vendor: "claude", Tokens: 40_000_000, CacheRead: 400_000_000, ListCostUSD: 600},
		{Day: d1, Vendor: "mistral", Tokens: 10_000_000, ListCostUSD: 20},
		{Day: d2, Vendor: "grok", Tokens: 1_000_000, ListCostUSD: 2},
		{Day: to, Vendor: "claude", Tokens: 999_000_000}, // the day after the range: left out
	}
	rate := func(it FleetPaidItem) (float64, string, bool) {
		if it.Currency == "EUR" {
			return 0.9, it.PeriodStart, true
		}
		return 0, "", false
	}
	got := FleetPaidEffective(items, days, from, to, rate)
	if got.Days != 30 || got.From != "2026-09-01" || got.To != "2026-10-01" || len(got.Vendors) != len(wire.FleetTokenVendors) {
		t.Fatalf("range %+v", got)
	}
	by := map[string]FleetPaidVendor{}
	for _, v := range got.Vendors {
		by[v.Vendor] = v
	}
	f := func(p *float64) float64 {
		if p == nil {
			return -1
		}
		return *p
	}
	for _, c := range []struct {
		vendor, status          string
		tokens, cacheRead       int64
		paid, perDay, eff, list float64
		items                   int
	}{
		{"mistral", "effective", 10_000_000, 0, 107.6087, 3.587, 10.7609, 2, 1},
		{"claude", "effective", 100_000_000, 900_000_000, 725, 24.1667, 7.25, 15, 2},
		{"agy", "not_metered", 0, 0, 20, 0.6667, -1, -1, 1},
		{"grok", "list_only", 1_000_000, 0, -1, -1, -1, 2, 0},
		{"qwen", "no_fx_rate", 0, 0, -1, -1, -1, -1, 1},
	} {
		v := by[c.vendor]
		if v.Status != c.status || v.Tokens != c.tokens || v.CacheRead != c.cacheRead || f(v.PaidUSD) != c.paid || f(v.PaidPerDayUSD) != c.perDay ||
			f(v.EffectiveUSDPerMTok) != c.eff || f(v.ListUSDPerMTok) != c.list || len(v.Items) != c.items {
			t.Errorf("%s: status %s tokens %d cache %d paid %v/day %v eff %v list %v items %d, want %+v", c.vendor, v.Status, v.Tokens, v.CacheRead,
				f(v.PaidUSD), f(v.PaidPerDayUSD), f(v.EffectiveUSDPerMTok), f(v.ListUSDPerMTok), len(v.Items), c)
		}
	}
	if m := by["mistral"].Items[0]; m.Days != 30 || f(m.FXRate) != 0.9 || m.FXRateDay == nil || *m.FXRateDay != "2026-07-01" || f(m.PaidUSD) != 107.6087 {
		t.Errorf("mistral share %+v", m)
	}
	if c := by["claude"].Items; c[0].Days != 30 || f(c[0].PaidUSD) != 600 || c[1].Days != 15 || f(c[1].PaidUSD) != 125 || c[0].FXRate != nil {
		t.Errorf("claude shares %+v", c)
	}
}

// SPL-2342: the read's days default to the last 30 whole UTC days; a bad
// day or a range over FleetPaidRangeMax days is refused.
func TestFleetPaidWindow(t *testing.T) {
	now := time.Date(2026, 10, 17, 9, 30, 0, 0, time.UTC)
	if f, to, why := FleetPaidWindow("", "", now); why != "" || f.Format(time.DateOnly) != "2026-09-17" || to.Format(time.DateOnly) != "2026-10-17" {
		t.Fatalf("default: %v %v %q", f, to, why)
	}
	if f, _, why := FleetPaidWindow("", "2026-08-01", now); why != "" || f.Format(time.DateOnly) != "2026-07-02" {
		t.Fatalf("to only: %v %q", f, why)
	}
	for _, q := range [][2]string{{"2026-13-01", ""}, {"", "yesterday"}, {"2026-10-01", "2026-10-01"}, {"2024-01-01", "2026-01-01"}} {
		if _, _, why := FleetPaidWindow(q[0], q[1], now); why == "" {
			t.Errorf("%v accepted", q)
		}
	}
}

// SPL-2342: CheckFleetPaidItem refuses each bad field.
func TestCheckFleetPaidItem(t *testing.T) {
	good := paidItem("op", "mistral", "subscription", 1, 594, "EUR", "2026-07-01", "2027-01-01")
	if why := CheckFleetPaidItem(good); why != "" {
		t.Fatalf("CONTROL: a good item refused: %s", why)
	}
	for name, mut := range map[string]func(*FleetPaidItem){
		"vendor":   func(i *FleetPaidItem) { i.Vendor = "gpt" },
		"kind":     func(i *FleetPaidItem) { i.Kind = "gift" },
		"label":    func(i *FleetPaidItem) { i.PlanLabel = " " },
		"quantity": func(i *FleetPaidItem) { i.Quantity = 0 },
		"amount":   func(i *FleetPaidItem) { i.Amount = 0 },
		"currency": func(i *FleetPaidItem) { i.Currency = "eur" },
		"end":      func(i *FleetPaidItem) { i.PeriodEnd = "2026-06-30" },
		"start":    func(i *FleetPaidItem) { i.PeriodStart = "2026-7-1" },
		"note":     func(i *FleetPaidItem) { i.Note = strings.Repeat("x", 2001) },
	} {
		it := good
		mut(&it)
		if CheckFleetPaidItem(it) == "" {
			t.Errorf("%s: a bad item passed", name)
		}
	}
}

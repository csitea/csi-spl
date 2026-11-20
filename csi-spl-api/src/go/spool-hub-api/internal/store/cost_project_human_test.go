package store

import (
	"context"
	"strings"
	"testing"
)

// Spec 123 13.8 row P02: the Human part, approved minutes x the price in
// force per day (cost_project_human.go). The day read is Postgres only
// (rlsStore); the fold runs on any store.

// humanEntry writes one hours entry of member in tenant (kind work unless
// absence is set).
func humanEntry(t *testing.T, pg *Postgres, tenant, member, day, state string, minutes int, absence bool) {
	t.Helper()
	kind, typ := "work", any(nil)
	if absence {
		kind, typ = "absence", "vacation"
	}
	if _, err := pg.execTenant(context.Background(), tenant, `INSERT INTO hours_entries
		(tenant_id, member_id, day, target, minutes, state, updated_by, kind, absence_type)
		VALUES ($1, $2, $3::date, 'ws', $4, $5, $2, $6, $7)`, tenant, member, day, minutes, state, kind, typ); err != nil {
		t.Fatalf("entry %s %s: %v", member, day, err)
	}
}

// hoursUnpriced is a member who books time and has no price.
const hoursUnpriced = "55555555-5555-4555-8555-555555555555"

// humanPrice sets member's price in tenant from day, in micros of cur an
// hour.
func humanPrice(t *testing.T, pg *Postgres, tenant, member, day string, amount int64, cur string) {
	t.Helper()
	if _, err := pg.execTenant(context.Background(), tenant, `INSERT INTO member_hourly_prices
		(tenant_id, member_id, valid_from, amount_micros, currency, set_by)
		VALUES ($1, $2, $3::date, $4, $5, 'HUM-owner')`, tenant, member, day, amount, cur); err != nil {
		t.Fatalf("price %s %s: %v", member, day, err)
	}
}

// humanPeriod writes member's hours period from..to in tenant, in state
// (frozen, returned or approved).
func humanPeriod(t *testing.T, pg *Postgres, tenant, member, from, to, state string) {
	t.Helper()
	if _, err := pg.execTenant(context.Background(), tenant, `INSERT INTO hours_periods
		(tenant_id, member_id, period_start, period_end, state, note, decided_by)
		VALUES ($1, $2, $3::date, $4::date, $5, 'test', 'HUM-owner')`, tenant, member, from, to, state); err != nil {
		t.Fatalf("period %s %s: %v", member, from, err)
	}
}

// humanUSD sums days' known USD micros and every minute.
func humanUSD(days []CostProjectHumanDay) (usd, minutes int64) {
	for _, d := range days {
		minutes += d.Minutes
		if d.USDMicros != nil {
			usd += *d.USDMicros
		}
	}
	return usd, minutes
}

// humanDay is the (day, currency) row of days: cur "" = the unpriced final
// row, "pending" = the pending row.
func humanDay(t *testing.T, days []CostProjectHumanDay, day, cur string) CostProjectHumanDay {
	t.Helper()
	for _, d := range days {
		c := ""
		if d.Currency != nil {
			c = *d.Currency
		}
		if d.Pending {
			c = "pending"
		}
		if d.Day == day && c == cur {
			return d
		}
	}
	t.Fatalf("no %s %q row in %+v", day, cur, days)
	return CostProjectHumanDay{}
}

// costHumanSeedMonth seeds workspace a's month (day d) and returns it:
//   - P costs 60 USD/h from day 1 and 120 USD/h from day 10, period frozen
//     days 1..15: 60 min on day 5 and 30 min on day 12 are 60 + 60 = 120 USD
//     (13.9 "a price changed mid-month"). Day 20 (approved, no period),
//     day 23 (approved, period returned) and day 8 (disputed) are pending:
//     40 + 20 + 10 min, no money.
//   - Q costs 90 EUR/h, period approved: 90 min on day 5 are 135 EUR, at the
//     day 3 rate 0.9 EUR per USD 150 USD. Day 7 (proposed) is pending: 25 min.
//   - R has no price, period frozen: 15 min on day 6 count, unpriced (13.9
//     "a member with no price").
//   - An absence row and a rejected row count nothing.
//
// Final priced: 270 USD over 180 min; 15 unpriced, 95 pending; 290 min.
func costHumanSeedMonth(t *testing.T, pg *Postgres, a string, day func(int) string) {
	t.Helper()
	humanPrice(t, pg, a, hoursMember, day(1), 60_000_000, "USD")
	humanPrice(t, pg, a, hoursMember, day(10), 120_000_000, "USD")
	humanPrice(t, pg, a, hoursPriceOther, day(1), 90_000_000, "EUR")
	humanPeriod(t, pg, a, hoursMember, day(1), day(15), "frozen")
	humanPeriod(t, pg, a, hoursMember, day(22), day(28), "returned")
	humanPeriod(t, pg, a, hoursPriceOther, day(1), day(28), "approved")
	humanPeriod(t, pg, a, hoursUnpriced, day(1), day(28), "frozen")
	humanEntry(t, pg, a, hoursMember, day(5), "approved", 60, false)
	humanEntry(t, pg, a, hoursMember, day(12), "approved", 30, false)
	humanEntry(t, pg, a, hoursMember, day(13), "approved", 480, true)
	humanEntry(t, pg, a, hoursMember, day(14), "rejected", 45, false)
	humanEntry(t, pg, a, hoursMember, day(20), "approved", 40, false)
	humanEntry(t, pg, a, hoursMember, day(23), "approved", 20, false)
	humanEntry(t, pg, a, hoursMember, day(8), "disputed", 10, false)
	humanEntry(t, pg, a, hoursPriceOther, day(5), "approved", 90, false)
	humanEntry(t, pg, a, hoursPriceOther, day(7), "proposed", 25, false)
	humanEntry(t, pg, a, hoursUnpriced, day(6), "approved", 15, false)
	if _, err := pg.PutFXRates(context.Background(), []FXRate{{Day: day(3), Quote: "EUR", Rate: 0.9, Source: "ECB"}}); err != nil {
		t.Fatal(err)
	}
}

// TestCostProjectHumanSum: costHumanSeedMonth reads 270 USD over 290 min,
// each final minute at its day's price, the EUR price converted at the rate
// of a few days earlier, the pending and unpriced minutes counted with no
// money; workspace B's minutes never reach A's read. No row names a member.
// CONTROLS: priced at today's price (the latest start day) the same minutes
// read 330 USD; with the period guard dropped (approved = the entry's state)
// the pending 40 min of day 20 and 20 min of day 23 are priced, 390 USD.
func TestCostProjectHumanSum(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	from, to, day := costTestMonth(t)
	a, b := newTenant(t, pg), newTenant(t, pg)
	costHumanSeedMonth(t, pg, a, day)
	humanPrice(t, pg, b, hoursMember, day(1), 60_000_000, "USD")
	humanPeriod(t, pg, b, hoursMember, day(1), day(28), "approved")
	humanEntry(t, pg, b, hoursMember, day(5), "approved", 600, false)

	q := CostProjectHumanQuery{Tenant: a, From: from, To: to, Currency: "USD"}
	days, err := pg.CostProjectHumanDays(ctx, q)
	if err != nil {
		t.Fatal(err)
	}
	if usd, min := humanUSD(days); usd != 270_000_000 || min != 290 || len(days) != 8 {
		t.Fatalf("A's days %+v: %d USD micros, %d min; want 270.00 USD, 290 min, 8 rows", days, usd, min)
	}
	if d := humanDay(t, days, day(6), ""); d.Minutes != 15 || d.AmountMicros != nil || d.USDMicros != nil {
		t.Errorf("day 6 unpriced row %+v: want R's 15 min, every amount null", d)
	}
	for n, want := range map[int]int64{20: 40, 23: 20, 8: 10, 7: 25} {
		if d := humanDay(t, days, day(n), "pending"); d.Minutes != want || d.Currency != nil || d.AmountMicros != nil || d.USDMicros != nil {
			t.Errorf("day %d pending row %+v: want %d min, no currency, every amount null", n, d, want)
		}
	}
	if d := humanDay(t, days, day(5), "EUR"); pv(d.AmountMicros) != int64(135_000_000) || pv(d.USDMicros) != int64(150_000_000) ||
		pv(d.EURMicros) != int64(135_000_000) {
		t.Errorf("day 5 EUR row %+v: want 135.00 EUR = 150.00 USD at the day 3 rate", d)
	}
	if d := humanDay(t, days, day(5), "USD"); pv(d.EURMicros) != int64(54_000_000) {
		t.Errorf("day 5 USD row %+v: want 60.00 USD = 54.00 EUR at the day 3 rate", d)
	}
	cp := CostProjectParts(CostProjectInput{Estate: true, HumanRead: true, Human: days})
	h := projectPart(t, cp, CostProjectHuman)
	if pv(h.USDMicros) != int64(270_000_000) || pv(h.SecondMicros) != int64(270_000_000) || pv(h.EURMicros) != int64(243_000_000) ||
		*h.Minutes != 290 || *h.UnpricedMinutes != 110 || *h.PendingMinutes != 95 || h.Completeness != CostProjectUnpriced {
		t.Errorf("human part %+v: want 270.00 USD, 243.00 EUR, 290 min of which 110 unpriced, 95 pending, unpriced", h)
	}
	costProjectSumsHold(t, cp)
	if !cp.Total.Partial {
		t.Error("total not partial with unpriced human minutes")
	}

	for _, c := range []struct {
		old, new string
		want     int64
	}{
		{"m.valid_from <= f.day", "m.valid_from <= current_date", 330_000_000},
		{"h.day BETWEEN hp.period_start AND hp.period_end AND hp.state IN ('frozen', 'approved')", "true", 390_000_000},
	} {
		saved := costProjectHumanDays
		costProjectHumanDays = strings.Replace(saved, c.old, c.new, 1)
		if costProjectHumanDays == saved {
			t.Fatalf("CONTROL %q: not in the query", c.old)
		}
		days, err = pg.CostProjectHumanDays(ctx, q)
		costProjectHumanDays = saved
		if err != nil {
			t.Fatal(err)
		}
		if usd, _ := humanUSD(days); usd != c.want {
			t.Errorf("CONTROL %q: the minutes read %d USD micros, want %d", c.new, usd, c.want)
		}
	}
}

// TestCostProjectHumanPart: Human is not_tracked on a store with no human
// read, a known 0 (complete) when the read found no minutes, and a day with
// no rate in the second currency is unpriced there and left out of it.
func TestCostProjectHumanPart(t *testing.T) {
	if h := projectPart(t, CostProjectParts(CostProjectInput{Estate: true}), CostProjectHuman); h.Completeness != CostProjectNotTracked || h.USDMicros != nil {
		t.Errorf("no human read: %+v, want not_tracked, null", h)
	}
	h := projectPart(t, CostProjectParts(CostProjectInput{HumanRead: true}), CostProjectHuman)
	if h.Completeness != CostProjectComplete || pv(h.USDMicros) != int64(0) || *h.Minutes != 0 {
		t.Errorf("no minutes: %+v, want a complete 0", h)
	}
	usd, eur := "USD", int64(0)
	one, two := int64(1_000_000), int64(2_000_000)
	h = costProjectHumanPart([]CostProjectHumanDay{
		{Day: "2011-03-01", Currency: &usd, Minutes: 60, AmountMicros: &one, USDMicros: &one, EURMicros: &one, SecondMicros: &one},
		{Day: "2011-03-02", Currency: &usd, Minutes: 120, AmountMicros: &two, USDMicros: &two, EURMicros: &eur},
	})
	if pv(h.USDMicros) != int64(3_000_000) || pv(h.SecondMicros) != int64(1_000_000) || h.Unpriced != 1 ||
		*h.UnpricedMinutes != 0 || h.Completeness != CostProjectUnpriced {
		t.Errorf("a day with no second rate: %+v, want USD 3.00, second 1.00 (day 2 left out), unpriced", h)
	}
}

// TestCostProjectHumanNotLeftOut: an hr line in the month read's parts (a
// hand cost entry or an allocated share of type hr) is in no part and never
// named in left_out with its amount, for the estate and for a workspace; the
// gcp line beside it still is. CONTROL: with the hr case dropped from
// costProjectOf the workspace names the hr line and its 30.00 USD.
func TestCostProjectHumanNotLeftOut(t *testing.T) {
	parts := []CostPart{
		{Source: CostSourceEntry, ProjectOrVendor: "ws hr", Kind: "hr", USDMicros: 30_000_000},
		{Source: CostSourceAllocated, ProjectOrVendor: "ws hr share", Kind: "hr", USDMicros: 4_000_000},
		{Source: "gcp", ProjectOrVendor: "p", Kind: "cloud_run", USDMicros: 1_000_000},
	}
	hrLeft := func(cp CostProject) (n int) {
		for _, l := range cp.LeftOut {
			if l.Kind == "hr" {
				n++
			}
		}
		return n
	}
	for _, estate := range []bool{true, false} {
		cp := CostProjectParts(CostProjectInput{Estate: estate, HumanRead: true, Parts: parts})
		if n := hrLeft(cp); n != 0 {
			t.Errorf("estate %v: %d hr lines in left_out %+v, want 0", estate, n, cp.LeftOut)
		}
		if h := projectPart(t, cp, CostProjectHuman); pv(h.USDMicros) != int64(0) {
			t.Errorf("estate %v: human %+v, want the 107 hours only (none here)", estate, h)
		}
		costProjectSumsHold(t, cp)
	}
	if ws := CostProjectParts(CostProjectInput{Parts: parts}); len(ws.LeftOut) != 1 || ws.LeftOut[0].Source != "gcp" {
		t.Errorf("workspace left out %+v: want the gcp line only", ws.LeftOut)
	}
	of := costProjectOf
	costProjectOf = func(p CostPart, estate bool) (string, bool) {
		if p.Kind == "hr" {
			return "", false
		}
		return of(p, estate)
	}
	drop := CostProjectParts(CostProjectInput{Parts: parts})
	costProjectOf = of
	if hrLeft(drop) != 2 {
		t.Errorf("CONTROL: with the hr case dropped left_out %+v still holds no hr line: the guard proves nothing", drop.LeftOut)
	}
}

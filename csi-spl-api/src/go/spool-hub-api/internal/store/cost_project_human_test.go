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

// humanPrice sets member's price in tenant from day, in USD micros an hour.
func humanPrice(t *testing.T, pg *Postgres, tenant, member, day string, usd int64) {
	t.Helper()
	if _, err := pg.execTenant(context.Background(), tenant, `INSERT INTO member_hourly_prices
		(tenant_id, member_id, valid_from, amount_micros, currency, set_by)
		VALUES ($1, $2, $3::date, $4, 'USD', 'HUM-owner')`, tenant, member, day, usd); err != nil {
		t.Fatalf("price %s %s: %v", member, day, err)
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

// TestCostProjectHumanSum: member P costs 60 USD/h from day 1 and 120 USD/h
// from day 10; 60 min on day 5 and 30 min on day 12 are 60 + 60 = 120 USD,
// each day at its own price (13.9 "a price changed mid-month"). Member Q has
// no price: his 90 min count, unpriced, money left out (13.9 "a member with
// no price"). An absence row and a rejected row count nothing; workspace
// B's minutes never reach A's read. No row names a member.
// CONTROL: priced at today's price (the latest start day) the same minutes
// read 180 USD.
func TestCostProjectHumanSum(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	from, to, day := costTestMonth(t)
	a, b := newTenant(t, pg), newTenant(t, pg)
	humanPrice(t, pg, a, hoursMember, day(1), 60_000_000)
	humanPrice(t, pg, a, hoursMember, day(10), 120_000_000)
	humanEntry(t, pg, a, hoursMember, day(5), "approved", 60, false)
	humanEntry(t, pg, a, hoursMember, day(12), "approved", 30, false)
	humanEntry(t, pg, a, hoursMember, day(13), "approved", 480, true)
	humanEntry(t, pg, a, hoursMember, day(14), "rejected", 45, false)
	humanEntry(t, pg, a, hoursPriceOther, day(5), "approved", 90, false)
	humanPrice(t, pg, b, hoursMember, day(1), 60_000_000)
	humanEntry(t, pg, b, hoursMember, day(5), "approved", 600, false)

	q := CostProjectHumanQuery{Tenant: a, From: from, To: to, Currency: "USD"}
	days, err := pg.CostProjectHumanDays(ctx, q)
	if err != nil {
		t.Fatal(err)
	}
	if usd, min := humanUSD(days); usd != 120_000_000 || min != 180 || len(days) != 3 {
		t.Fatalf("A's days %+v: %d USD micros, %d min; want 120.00 USD, 180 min, 3 rows", days, usd, min)
	}
	if d := days[0]; d.Day != day(5) || d.Currency != nil || d.Minutes != 90 || d.AmountMicros != nil || d.USDMicros != nil {
		t.Errorf("day 5 unpriced row %+v: want Q's 90 min, every amount null", d)
	}
	cp := CostProjectParts(CostProjectInput{Estate: true, HumanRead: true, Human: days})
	h := projectPart(t, cp, CostProjectHuman)
	if pv(h.USDMicros) != int64(120_000_000) || pv(h.SecondMicros) != int64(120_000_000) ||
		*h.Minutes != 180 || *h.UnpricedMinutes != 90 || h.Completeness != CostProjectUnpriced {
		t.Errorf("human part %+v: want 120.00 USD, 180 min of which 90 unpriced, unpriced", h)
	}
	costProjectSumsHold(t, cp)
	if !cp.Total.Partial {
		t.Error("total not partial with unpriced human minutes")
	}

	saved := costProjectHumanDays
	costProjectHumanDays = strings.Replace(saved, "m.valid_from <= h.day", "m.valid_from <= current_date", 1)
	days, err = pg.CostProjectHumanDays(ctx, q)
	costProjectHumanDays = saved
	if err != nil {
		t.Fatal(err)
	}
	if usd, _ := humanUSD(days); usd != 180_000_000 {
		t.Errorf("CONTROL: at today's price the minutes read %d USD micros, want 180.00", usd)
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

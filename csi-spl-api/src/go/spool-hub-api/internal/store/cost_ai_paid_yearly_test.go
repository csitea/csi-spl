package store

import (
	"testing"
	"time"
)

// SPL-3890 (owner HUM-10, t1 d9072c0e msg 35a3729c): a payment made once for
// 12 months counts 1/12 of it in a month, pro rata by days, never the whole
// amount in the month it was paid. 365 USD for [2026-10-01, 2027-10-01) is
// 1 USD a day: 31 USD in October, 30 in November, nothing in September 2026
// or October 2027. RED CONTROL: the same payment stored as one month (the
// prd row this bug came from) puts all 365 USD into October.
func TestAIPaidYearlyItemSpreadsOverItsYear(t *testing.T) {
	yearly := paidItem("op", "mistral", "topup", 1, 365, "USD", "2026-10-01", "2027-10-01")
	for _, c := range []struct {
		month string
		want  int64
	}{{"2026-09-01", 0}, {"2026-10-01", 31_000_000}, {"2026-11-01", 30_000_000}, {"2027-09-01", 30_000_000}, {"2027-10-01", 0}} {
		if got := aiPaidMonthMicros(t, yearly, c.month); got != c.want {
			t.Fatalf("yearly item, month %s: %d USD micros, want %d", c.month, got, c.want)
		}
	}
	monthly := yearly
	monthly.PeriodEnd = "2026-11-01"
	// 365/31 USD a day rounds to whole micros: within 31 micros of it all.
	if got := aiPaidMonthMicros(t, monthly, "2026-10-01"); got < 365_000_000-31 || got > 365_000_000+31 {
		t.Fatalf("red control: a one-month item reads %d micros in its month, want all of 365000000", got)
	}
}

// aiPaidMonthMicros is it's USD micros in the calendar month starting at month.
func aiPaidMonthMicros(t *testing.T, it FleetPaidItem, month string) int64 {
	t.Helper()
	from, err := time.Parse(time.DateOnly, month)
	if err != nil {
		t.Fatal(err)
	}
	days, unpriced := aiPaidItemDays([]FleetPaidItem{it}, nil, from, from.AddDate(0, 1, 0))
	if len(unpriced) != 0 {
		t.Fatalf("a USD item has unpriced days %v", unpriced)
	}
	var sum int64
	for _, p := range aiPaidParts(days, nil) {
		sum += p.USDMicros
	}
	return sum
}

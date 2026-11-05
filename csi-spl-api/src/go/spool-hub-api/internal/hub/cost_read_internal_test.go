package hub

import (
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 123 lane 4b: the month math of GET /v1/tenant/costs. N ("n of N
// days") is the days of the month that ended: today is still being read.
func TestCostWindow(t *testing.T) {
	at := func(s string) time.Time {
		v, err := time.Parse(time.RFC3339, s)
		if err != nil {
			t.Fatal(err)
		}
		return v
	}
	for _, c := range []struct {
		month, now           string
		from, to             string
		days, ended          int
		soFar                bool
		coverTo, refusedWith string
	}{
		{"", "2026-10-15T09:00:00Z", "2026-10-01", "2026-11-01", 31, 14, true, "2026-10-15", ""},
		{"2026-10", "2026-10-01T00:00:00Z", "2026-10-01", "2026-11-01", 31, 0, true, "2026-10-01", ""},
		{"2026-10", "2026-11-01T00:00:00Z", "2026-10-01", "2026-11-01", 31, 31, false, "2026-11-01", ""},
		{"2026-09", "2026-10-15T09:00:00Z", "2026-09-01", "2026-10-01", 30, 30, false, "2026-10-01", ""},
		{"2024-02", "2026-10-15T09:00:00Z", "2024-02-01", "2024-03-01", 29, 29, false, "2024-03-01", ""},
		{"2025-12", "2025-12-31T23:59:59Z", "2025-12-01", "2026-01-01", 31, 30, true, "2025-12-31", ""},
		// a +03:00 clock is read in UTC: 00:30 local on 11-01 is still October
		{"", "2026-11-01T00:30:00+03:00", "2026-10-01", "2026-11-01", 31, 30, true, "2026-10-31", ""},
		{"2026-11", "2026-10-15T09:00:00Z", "", "", 0, 0, false, "", "month 2026-11 has not started"},
		{"2026-1", "2026-10-15T09:00:00Z", "", "", 0, 0, false, "", "month must be YYYY-MM"},
		{"1999-12", "2026-10-15T09:00:00Z", "", "", 0, 0, false, "", "month must be YYYY-MM"},
		{"2026-10-01", "2026-10-15T09:00:00Z", "", "", 0, 0, false, "", "month must be YYYY-MM"},
	} {
		w, why := costWindow(c.month, at(c.now))
		if why != c.refusedWith {
			t.Errorf("%q at %s: refused %q, want %q", c.month, c.now, why, c.refusedWith)
			continue
		}
		if why != "" {
			continue
		}
		if w.From != c.from || w.To != c.to || w.Days != c.days || w.Ended != c.ended || w.SoFar != c.soFar || w.CoverTo != c.coverTo {
			t.Errorf("%q at %s: %+v, want from %s to %s days %d ended %d so_far %t cover_to %s",
				c.month, c.now, w, c.from, c.to, c.days, c.ended, c.soFar, c.coverTo)
		}
	}
}

// The answer's arithmetic: totals in both currencies, each part's share of
// the USD total (null while it is 0), the hand marker, and "n of N" with the
// days no coverage row records.
func TestCostMonthAnswer(t *testing.T) {
	w, _ := costWindow("2026-10", time.Date(2026, 10, 11, 8, 0, 0, 0, time.UTC))
	b := costMonthAnswer(w, true, "EUR", store.CostMonth{
		Parts: []store.CostPart{
			{Estate: true, Source: "gcp", ProjectOrVendor: "csi-spl-prd", Kind: "cloud_run", Origin: "billing_export", USDMicros: 3_000_000, EURMicros: 2_700_000},
			{Source: "hand", ProjectOrVendor: "vendor", Kind: "subscription", Origin: "invoice", USDMicros: 1_000_000, EURMicros: 900_000},
		},
		Coverage: []store.CostSourceDays{{Source: "gcp", OK: 6, Partial: 1, Missing: 1}},
	})
	if b.Total.USDMicros != 4_000_000 || b.Total.EURMicros != 3_600_000 || b.Scope != "estate" || b.Status != "so_far" || b.To != "2026-10-31" || b.Ended != 10 {
		t.Fatalf("answer %+v", b)
	}
	if *b.Parts[0].Pct != 75 || *b.Parts[1].Pct != 25 || b.Parts[0].Hand || !b.Parts[1].Hand {
		t.Errorf("parts %+v %+v", b.Parts[0], b.Parts[1])
	}
	if c := b.Coverage[0]; c.Days != 10 || c.Unrecorded != 2 {
		t.Errorf("coverage %+v, want N 10 and 2 days unrecorded", c)
	}
	z := costMonthAnswer(w, false, "EUR", store.CostMonth{Parts: []store.CostPart{{Source: "fleet_tokens.x", Units: 107}}})
	if z.Parts[0].Pct != nil || z.Scope != "workspace" || z.Coverage == nil {
		t.Errorf("a 0 USD month: %+v", z)
	}
}

// SPL-4824 R7 W1: an unpriced cost entry (no rate, so no USD and no second
// amount) is left out of the second-currency total, as of USD; a priced
// part without a rate still blanks it (never a guess). RED CONTROL: fails
// when costMonthAnswer sets complete = false for an Unpriced part.
func TestCostMonthAnswerUnpricedEntryKeepsSecondTotal(t *testing.T) {
	w, _ := costWindow("2026-10", time.Date(2026, 10, 11, 8, 0, 0, 0, time.UTC))
	eur := int64(2_700_000)
	gcp := store.CostPart{Estate: true, Source: "gcp", ProjectOrVendor: "p", Kind: "cloud_run", USDMicros: 3_000_000, EURMicros: eur, SecondMicros: &eur}
	entry := store.CostPart{Estate: true, Source: store.CostSourceEntry, ProjectOrVendor: "suite", Kind: "cloud", Origin: "hand",
		EntryMicros: 5_000_000, EntryCurrency: "CHF", Unpriced: true}
	b := costMonthAnswer(w, true, "EUR", store.CostMonth{Parts: []store.CostPart{gcp, entry}})
	if b.Total.SecondMicros == nil || *b.Total.SecondMicros != eur || b.Total.USDMicros != 3_000_000 {
		t.Fatalf("total %+v, want second %d kept beside the unpriced entry", b.Total, eur)
	}
	gcp.SecondMicros = nil
	if b := costMonthAnswer(w, true, "EUR", store.CostMonth{Parts: []store.CostPart{gcp, entry}}); b.Total.SecondMicros != nil {
		t.Errorf("a priced part with no rate: second total %d, want none", *b.Total.SecondMicros)
	}
}

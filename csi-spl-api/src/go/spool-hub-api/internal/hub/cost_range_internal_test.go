package hub

import (
	"net/url"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-6300: the month range's windows and what each part field means over
// a range (cost_range.go). Synthetic amounts only.

func TestCostRangeWindows(t *testing.T) {
	now := time.Date(2026, 11, 23, 9, 0, 0, 0, time.UTC)
	for _, c := range []struct {
		q                string
		n                int
		first, last, why string
		days, ended      int
	}{
		{"", 1, "2026-11", "2026-11", "", 30, 22},
		{"month=2026-10", 1, "2026-10", "2026-10", "", 31, 31},
		{"from=2026-10&to=2026-10", 1, "2026-10", "2026-10", "", 31, 31},
		{"from=2026-09&to=2026-11", 3, "2026-09", "2026-11", "", 30 + 31 + 30, 30 + 31 + 22},
		{"from=2024-12&to=2026-11", 24, "2024-12", "2026-11", "", 0, 0},
		{"from=2024-11&to=2026-11", 0, "", "", "a range is at most 24 months", 0, 0},
		{"from=2026-11&to=2026-12", 0, "", "", "month 2026-12 has not started", 0, 0},
		{"from=2026-11&to=2026-10", 0, "", "", "from 2026-11 is after to 2026-10", 0, 0},
		{"from=1999-12&to=2000-01", 0, "", "", "from must be YYYY-MM", 0, 0},
	} {
		q, _ := url.ParseQuery(c.q)
		wins, why := costRangeWindows(q, now)
		if why != c.why || len(wins) != c.n {
			t.Errorf("%q: %d windows, refused %q; want %d, %q", c.q, len(wins), why, c.n, c.why)
			continue
		}
		if why != "" {
			continue
		}
		span := costSpanWindow(wins)
		if wins[0].Month != c.first || wins[len(wins)-1].Month != c.last {
			t.Errorf("%q: %s..%s, want %s..%s", c.q, wins[0].Month, wins[len(wins)-1].Month, c.first, c.last)
		}
		if c.days != 0 && (span.Days != c.days || span.Ended != c.ended) {
			t.Errorf("%q: days %d ended %d, want %d %d", c.q, span.Days, span.Ended, c.days, c.ended)
		}
		if span.SoFar != (c.last == "2026-11") || span.From != wins[0].From || span.To != wins[len(wins)-1].To {
			t.Errorf("%q: span %+v", c.q, span)
		}
	}
}

// TestCostMergeParts: one part per key, in first-seen order; amounts and
// days summed; list null while every month's is; second null once any
// month's is; the latest month's rate and the earliest's first rate day.
// CONTROL: a part of another kind stays apart.
func TestCostMergeParts(t *testing.T) {
	i64 := func(v int64) *int64 { return &v }
	f64 := func(v float64) *float64 { return &v }
	s := func(v string) *string { return &v }
	gcp := store.CostPart{Estate: true, Source: "gcp", ProjectOrVendor: "p", Kind: "run", Origin: "billing_export"}
	jan, feb, mar := gcp, gcp, gcp
	jan.USDMicros, jan.EURMicros, jan.Days, jan.Units = 1, 2, 3, 0.5
	jan.SecondMicros, jan.FXRate, jan.FXRateDay, jan.FXRateFirstDay = i64(10), f64(0.9), s("2026-01-31"), s("2026-01-01")
	feb.USDMicros, feb.EURMicros, feb.Days, feb.Units, feb.ListValueMicros = 10, 20, 4, 1.5, i64(7)
	feb.SecondMicros, feb.FXRate, feb.FXRateDay, feb.FXRateFirstDay = i64(20), f64(0.8), s("2026-02-28"), s("2026-02-01")
	mar.USDMicros, mar.Days = 100, 5
	other := gcp
	other.Kind, other.USDMicros = "storage", 1000

	got := costMergeParts([]store.CostPart{jan, other, feb})
	if len(got) != 2 || got[0].Kind != "run" || got[1].Kind != "storage" {
		t.Fatalf("CONTROL: %+v, want run then storage", got)
	}
	p := got[0]
	if p.USDMicros != 11 || p.EURMicros != 22 || p.Days != 7 || p.Units != 2 || p.ListValueMicros == nil || *p.ListValueMicros != 7 {
		t.Errorf("sums: %+v", p)
	}
	if p.SecondMicros == nil || *p.SecondMicros != 30 || *p.FXRate != 0.8 || *p.FXRateDay != "2026-02-28" || *p.FXRateFirstDay != "2026-01-01" {
		t.Errorf("second and rates: %+v", p)
	}
	if *jan.SecondMicros != 10 {
		t.Errorf("the merge changed its input: jan second %d", *jan.SecondMicros)
	}
	got = costMergeParts([]store.CostPart{jan, feb, mar}) // mar: no rate
	if got[0].SecondMicros != nil || got[0].USDMicros != 111 || *got[0].FXRate != 0.8 {
		t.Errorf("a month without a rate: %+v, want second null, rate kept", got[0])
	}
}

// TestCostMergeRange: the months' coverage, burn and AI parts summed; one
// month passes as it is.
func TestCostMergeRange(t *testing.T) {
	cm := func(usd int64, ok int) store.CostMonth {
		return store.CostMonth{Parts: []store.CostPart{{Source: "gcp", ProjectOrVendor: "p", USDMicros: usd}},
			Coverage: []store.CostSourceDays{{Source: "gcp", OK: ok, Missing: 1}}}
	}
	d := func(tok int64) costReadParts {
		return costReadParts{burn: []store.WorkspaceTokenPart{{Workspace: "w", Vendor: "c", Tokens: tok, Days: 1}},
			ai: &store.AIPaidMonth{Parts: []store.CostPart{{Source: "ai_paid", ProjectOrVendor: "c", USDMicros: tok}},
				Coverage: store.CostSourceDays{Source: "ai_paid", OK: 2}, ShareFrom: "2026-01-05"}}
	}
	one, oneD := costMergeRange([]store.CostMonth{cm(5, 3)}, []costReadParts{d(7)})
	if one.Parts[0].USDMicros != 5 || oneD.burn[0].Tokens != 7 {
		t.Fatalf("one month: %+v %+v", one, oneD)
	}
	m, md := costMergeRange([]store.CostMonth{cm(5, 3), cm(6, 4)}, []costReadParts{d(7), d(8)})
	if len(m.Parts) != 1 || m.Parts[0].USDMicros != 11 || m.Coverage[0].OK != 7 || m.Coverage[0].Missing != 2 {
		t.Errorf("lines: %+v", m)
	}
	if md.burn[0].Tokens != 15 || md.burn[0].Days != 2 || md.ai.Parts[0].USDMicros != 15 || md.ai.Coverage.OK != 4 || md.ai.ShareFrom != "2026-01-05" {
		t.Errorf("gathered: %+v ai %+v", md, md.ai)
	}
}

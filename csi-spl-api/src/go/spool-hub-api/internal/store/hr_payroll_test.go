package store

import (
	"context"
	"crypto/rand"
	"errors"
	"math/big"
	"slices"
	"testing"
)

// SPL-5433 step c: made-up people, lines and rates only.

func hrLine(person, comp string, amount float64, source string) CostEntry {
	return CostEntry{ID: uid(""), Type: "hr", Label: comp, Amount: amount, Currency: "EUR", Period: "2026-10",
		PersonID: person, Component: comp, Source: source, PeriodKind: "month"}
}

// The employer side is gross x rate, per rated component and employment type;
// benefits are cost but not gross; a yearly line and another month are left
// out; the totals add up.
func TestComputeHRPayrollEmployerSide(t *testing.T) {
	people := []HRPerson{
		{ID: "p1", Code: "E-01", EmploymentType: "employee"},
		{ID: "p2", Code: "E-02", EmploymentType: "owner_management"},
		{ID: "p3", Code: "E-03", EmploymentType: "contractor"},
	}
	lines := []CostEntry{
		hrLine("p1", "monthly_salary", 4000, "payslip"),
		hrLine("p1", "overtime", 200, "payslip"),
		hrLine("p1", "lunch_benefit", 100, ""),
		hrLine("p2", "owner_salary", 3000, ""),
		hrLine("p3", "hourly_pay", 1000, ""),
	}
	year := hrLine("p1", "bonus", 9999, "")
	year.Period, year.PeriodKind = "2026-01", "year"
	other := hrLine("p1", "bonus", 7777, "")
	other.Period = "2026-09"
	lines = append(lines, year, other)
	rates := []HRRate{
		{Year: 2026, Component: "tyel_employer", RatePct: 10, AppliesTo: []string{"employee", "hourly"}},
		{Year: 2026, Component: "accident_insurance", RatePct: 0.5, AppliesTo: []string{"employee", "hourly", "owner_management"}},
		{Year: 2025, Component: "unemployment_employer", RatePct: 50, AppliesTo: []string{"employee"}},
	}
	p := ComputeHRPayroll("2026-10", people, lines, rates, DefaultHRComponents)
	if p.Year != 2026 || len(p.People) != 3 || p.Flags != 0 {
		t.Fatalf("payroll: %+v", p)
	}
	e1, e2, e3 := p.People[0], p.People[1], p.People[2]
	if e1.Code != "E-01" || e1.Gross != 4200 || e1.Other != 100 {
		t.Fatalf("E-01 gross/other: %+v", e1)
	}
	// tyel 420 + accident 21; the 2025 rate is not 2026's
	if len(e1.Employer) != 2 || e1.Employer[0].Component != "tyel_employer" || e1.Employer[0].Computed != 420 ||
		e1.Employer[1].Component != "accident_insurance" || e1.Employer[1].Computed != 21 {
		t.Fatalf("E-01 employer: %+v", e1.Employer)
	}
	if e1.EmployerTotal != 441 || e1.Cost != 4741 {
		t.Errorf("E-01 totals: employer %v cost %v, want 441 4741", e1.EmployerTotal, e1.Cost)
	}
	if len(e2.Employer) != 1 || e2.Employer[0].Component != "accident_insurance" || e2.Employer[0].Computed != 15 || e2.Cost != 3015 {
		t.Errorf("E-02 (owner, accident only): %+v", e2)
	}
	if len(e3.Employer) != 0 || e3.Cost != 1000 {
		t.Errorf("E-03 (contractor, no rate applies): %+v", e3)
	}
	if len(p.Totals) != 1 || p.Totals[0].Gross != 8200 || p.Totals[0].EmployerTotal != 456 || p.Totals[0].Cost != 8756 || p.Totals[0].ToBook != 3 {
		t.Errorf("totals: %+v", p.Totals)
	}
	if bs := HRBookings(p); len(bs) != 3 {
		t.Errorf("bookings: %+v, want 3", bs)
	}
}

// A typed (payslip) value wins and a difference beyond a cent is flagged; a
// booked value equal to the calculation is fine, one the calculation moved
// away from is stale and rebooked; a booked line with no rate any more is
// stale and removed, not rebooked.
func TestComputeHRPayrollTypedBookedFlags(t *testing.T) {
	people := []HRPerson{{ID: "p1", Code: "E-01", EmploymentType: "employee"}}
	rates := []HRRate{
		{Year: 2026, Component: "tyel_employer", RatePct: 17.5, AppliesTo: []string{"employee"}},
		{Year: 2026, Component: "unemployment_employer", RatePct: 0.2, AppliesTo: []string{"employee"}},
		{Year: 2026, Component: "accident_insurance", RatePct: 1, AppliesTo: []string{"employee"}},
		{Year: 2026, Component: "group_life_insurance", RatePct: 0.06, AppliesTo: []string{"employee"}},
	}
	stale := hrLine("p1", "accident_insurance", 30, HRComputedSource+" 2026 rates")
	gone := hrLine("p1", "health_insurance", 12, HRComputedSource+" 2026 rates")
	lines := []CostEntry{
		hrLine("p1", "monthly_salary", 3000, "payslip"),
		hrLine("p1", "tyel_employer", 525.01, "payslip"),                    // within a cent: no flag
		hrLine("p1", "unemployment_employer", 7, "payslip"),                 // computed 6: diff
		hrLine("p1", "group_life_insurance", 1.8, HRComputedSource+" 2026"), // equal: fine
		stale, gone,
	}
	p := ComputeHRPayroll("2026-10", people, lines, rates, DefaultHRComponents)
	by := map[string]HRPayrollLine{}
	for _, l := range p.People[0].Employer {
		by[l.Component] = l
	}
	if l := by["tyel_employer"]; l.Computed != 525 || l.Typed == nil || l.Amount != 525.01 || l.Flag != "" {
		t.Errorf("tyel: %+v", l)
	}
	if l := by["unemployment_employer"]; l.Computed != 6 || l.Amount != 7 || l.Diff != 1 || l.Flag != "diff" {
		t.Errorf("unemployment: %+v", l)
	}
	if l := by["group_life_insurance"]; l.Booked == nil || l.Flag != "" || l.Amount != 1.8 {
		t.Errorf("group life: %+v", l)
	}
	if l := by["accident_insurance"]; l.Computed != 30 || l.Flag != "" {
		t.Errorf("accident (booked 30 = computed 30): %+v", l)
	}
	if l := by["health_insurance"]; l.RatePct != nil || l.Flag != "stale" || l.Amount != 12 {
		t.Errorf("health (booked, no rate): %+v", l)
	}
	if p.Flags != 2 || p.People[0].Flags != 2 {
		t.Errorf("flags: %d / %d, want 2", p.Flags, p.People[0].Flags)
	}
	if bs := HRBookings(p); len(bs) != 0 {
		t.Errorf("bookings: %+v, want none (typed, booked-equal, no-rate)", bs)
	}
	ids := HRStaleBooked("2026-10", lines, p, HRBookings(p))
	if !slices.Equal(ids, []string{gone.ID}) {
		t.Errorf("stale booked: %v, want only the no-rate line %s", ids, gone.ID)
	}
	// the salary moves: the booked accident line is stale and rebooked
	lines[0].Amount = 4000
	p = ComputeHRPayroll("2026-10", people, lines, rates, DefaultHRComponents)
	bs := HRBookings(p)
	var acc []HRBooking
	for _, b := range bs {
		if b.Component == "accident_insurance" {
			acc = append(acc, b)
		}
	}
	if len(acc) != 1 || acc[0].Amount != 40 {
		t.Fatalf("rebook accident: %+v", bs)
	}
	if ids := HRStaleBooked("2026-10", lines, p, bs); !slices.Contains(ids, stale.ID) || !slices.Contains(ids, gone.ID) {
		t.Errorf("stale booked after the move: %v, want %s and %s", ids, stale.ID, gone.ID)
	}
}

func TestCheckHRRate(t *testing.T) {
	ok := HRRate{Year: 2026, Component: "tyel_employer", RatePct: 17.3456, AppliesTo: []string{"employee"}, SetBy: "op"}
	if why := CheckHRRate(ok, DefaultHRComponents); why != "" {
		t.Fatalf("good rate refused: %s", why)
	}
	for why, mut := range map[string]func(*HRRate){
		"year":         func(r *HRRate) { r.Year = 1999 },
		"not employer": func(r *HRRate) { r.Component = "monthly_salary" },
		"unknown":      func(r *HRRate) { r.Component = "nope" },
		"yel":          func(r *HRRate) { r.Component = "yel" },
		"negative":     func(r *HRRate) { r.RatePct = -1 },
		"100":          func(r *HRRate) { r.RatePct = 100 },
		"5 decimals":   func(r *HRRate) { r.RatePct = 1.23456 },
		"no types":     func(r *HRRate) { r.AppliesTo = nil },
		"bad type":     func(r *HRRate) { r.AppliesTo = []string{"intern"} },
		"dup type":     func(r *HRRate) { r.AppliesTo = []string{"employee", "employee"} },
		"no by":        func(r *HRRate) { r.SetBy = " " },
	} {
		r := ok
		r.AppliesTo = slices.Clone(ok.AppliesTo)
		mut(&r)
		if CheckHRRate(r, DefaultHRComponents) == "" {
			t.Errorf("%s: accepted %+v", why, r)
		}
	}
}

// Set, replace, list and delete a rate, on both drivers. A random year keeps
// runs on a shared database apart.
func TestHRRatesStore(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rs := st.(HRRateStore)
			n, err := rand.Int(rand.Reader, big.NewInt(101))
			if err != nil {
				t.Fatal(err)
			}
			year := 2000 + int(n.Int64())
			_ = rs.DeleteHRRate(ctx, year, "tyel_employer")
			_ = rs.DeleteHRRate(ctx, year, "accident_insurance")
			r, err := rs.SetHRRate(ctx, HRRate{Year: year, Component: "tyel_employer", RatePct: 17.3456, AppliesTo: []string{"employee", "hourly"}, Source: "made-up", SetBy: "op"})
			if err != nil || r.RatePct != 17.3456 || r.SetAt.IsZero() {
				t.Fatalf("set: %+v %v", r, err)
			}
			if _, err := rs.SetHRRate(ctx, HRRate{Year: year, Component: "tyel_employer", RatePct: 18, AppliesTo: []string{"employee"}, SetBy: "op2"}); err != nil {
				t.Fatal(err)
			}
			if _, err := rs.SetHRRate(ctx, HRRate{Year: year, Component: "accident_insurance", RatePct: 0.5, AppliesTo: []string{"owner_management"}, SetBy: "op"}); err != nil {
				t.Fatal(err)
			}
			if _, err := rs.SetHRRate(ctx, HRRate{Year: year, Component: "monthly_salary", RatePct: 1, AppliesTo: []string{"employee"}, SetBy: "op"}); err == nil {
				t.Error("a pay component got a rate")
			}
			got, err := rs.ListHRRates(ctx, year)
			if err != nil || len(got) != 2 {
				t.Fatalf("list: %+v %v", got, err)
			}
			if got[0].Component != "accident_insurance" || got[1].Component != "tyel_employer" || got[1].RatePct != 18 ||
				!slices.Equal(got[1].AppliesTo, []string{"employee"}) || got[1].SetBy != "op2" {
				t.Errorf("list: %+v", got)
			}
			if err := rs.DeleteHRRate(ctx, year, "tyel_employer"); err != nil {
				t.Fatal(err)
			}
			if err := rs.DeleteHRRate(ctx, year, "tyel_employer"); !errors.Is(err, ErrNotFound) {
				t.Errorf("second delete: %v, want ErrNotFound", err)
			}
			_ = rs.DeleteHRRate(ctx, year, "accident_insurance")
		})
	}
}

package store

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// SPL-5433, rdb 0280: the components are the seed, on both drivers.
func TestHRComponentsAreTheSeed(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			got, err := st.(HRCostStore).ListHRComponents(ctx)
			if err != nil {
				t.Fatal(err)
			}
			if !slices.Equal(got, DefaultHRComponents) {
				t.Fatalf("components drifted from DefaultHRComponents (rdb 0280 seed):\n got %v\nwant %v", got, DefaultHRComponents)
			}
			for _, c := range got {
				if !slices.Contains(HRGroups, c.Group) {
					t.Errorf("%s: group %q not in HRGroups", c.Component, c.Group)
				}
			}
		})
	}
}

// SPL-5433: a person is a code; the name comes back only with names = true;
// a taken code is ErrConflict; a bad person never reaches the table.
func TestHRPeopleNames(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			hs := st.(HRCostStore)
			code := "T-" + digitsOf(uid(""))
			p, err := hs.CreateHRPerson(ctx, HRPerson{Code: code, Name: "FirstName LastName", Department: "Dev", EmploymentType: "employee", BirthYear: 1990, CreatedBy: "op"})
			if err != nil || !uuidRe.MatchString(p.ID) || p.Name != "FirstName LastName" {
				t.Fatalf("create: %+v %v", p, err)
			}
			if _, err := hs.CreateHRPerson(ctx, HRPerson{Code: code, Name: "Other", EmploymentType: "hourly", CreatedBy: "op"}); !errors.Is(err, ErrConflict) {
				t.Fatalf("taken code: %v, want ErrConflict", err)
			}
			for why, bad := range map[string]HRPerson{
				"lower code": {Code: "e-01", Name: "x", EmploymentType: "employee"}, "no name": {Code: "Z-99", Name: " ", EmploymentType: "employee"},
				"bad type": {Code: "Z-98", Name: "x", EmploymentType: "intern"}, "bad year": {Code: "Z-97", Name: "x", EmploymentType: "employee", BirthYear: 1800},
			} {
				bad.CreatedBy = "op"
				if _, err := hs.CreateHRPerson(ctx, bad); err == nil {
					t.Errorf("%s: stored", why)
				}
			}
			find := func(names bool) HRPerson {
				ps, err := hs.ListHRPeople(ctx, names)
				if err != nil {
					t.Fatal(err)
				}
				for _, x := range ps {
					if x.ID == p.ID {
						return x
					}
				}
				t.Fatalf("person %s not listed", p.ID)
				return HRPerson{}
			}
			if got := find(false); got.Name != "" || got.Code != code || got.BirthYear != 1990 || got.Department != "Dev" {
				t.Errorf("without names: %+v", got)
			}
			if got := find(true); got.Name != "FirstName LastName" {
				t.Errorf("with names: %+v", got)
			}
		})
	}
}

// digitsOf is 4 digits made from s, for a unique code per run.
func digitsOf(s string) string {
	out := []byte{}
	for i := 0; len(out) < 4; i++ {
		out = append(out, '0'+s[i%len(s)]%10)
	}
	return string(out)
}

// SPL-5433: the name table's policy hides it unless app.costs_names is on,
// even in the operator scope.
func TestHRPersonNamesNeedTheFlag(t *testing.T) {
	ctx := context.Background()
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("no SPOOL_TEST_PG_DSN")
	}
	if _, err := pg.CreateHRPerson(ctx, HRPerson{Code: "N-" + digitsOf(uid("")), Name: "FirstName LastName", EmploymentType: "contractor", CreatedBy: "op"}); err != nil {
		t.Fatal(err)
	}
	var without, with int
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		if err := tx.QueryRow(ctx, `SELECT count(*) FROM hr_person_names`).Scan(&without); err != nil {
			return err
		}
		if _, err := tx.Exec(ctx, pgCostsNames); err != nil {
			return err
		}
		return tx.QueryRow(ctx, `SELECT count(*) FROM hr_person_names`).Scan(&with)
	}); err != nil {
		t.Fatal(err)
	}
	if without != 0 || with == 0 {
		t.Fatalf("names visible without the flag: %d, with it: %d; want 0 and > 0", without, with)
	}
}

// SPL-5433, owner poll a82c0089 answer 2 B: a month closes on the 6th of the
// next month 00:00 Europe/Helsinki; the admin reopens with a reason and
// closes again.
func TestCostPeriodLock(t *testing.T) {
	ctx := context.Background()
	if got, want := CostMonthClosesAt("2026-10"), time.Date(2026, 11, 5, 22, 0, 0, 0, time.UTC); !got.Equal(want) {
		t.Fatalf("2026-10 closes at %s, want %s (00:00 EET on 6 Nov)", got, want)
	}
	if got, want := CostMonthClosesAt("2026-12"), time.Date(2027, 1, 5, 22, 0, 0, 0, time.UTC); !got.Equal(want) {
		t.Fatalf("2026-12 closes at %s, want %s", got, want)
	}
	if got, want := CostMonthClosesAt("2026-05"), time.Date(2026, 6, 5, 21, 0, 0, 0, time.UTC); !got.Equal(want) {
		t.Fatalf("2026-05 closes at %s, want %s (00:00 EEST)", got, want)
	}
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			hs := st.(HRCostStore)
			// a month far back so no other test's row is in the way
			month := "19" + digitsOf(uid(""))[:2] + "-03"
			at := CostMonthClosesAt(month)
			state := func(now time.Time) CostPeriod {
				p, err := hs.CostPeriodState(ctx, month, now)
				if err != nil {
					t.Fatal(err)
				}
				return p
			}
			if p := state(at.Add(-time.Second)); p.Closed {
				t.Fatalf("closed before the 6th: %+v", p)
			}
			if p := state(at); !p.Closed || p.ClosedAt == nil {
				t.Fatalf("open on the 6th: %+v", p)
			}
			if _, err := hs.SetCostPeriod(ctx, month, false, "admin", " ", at); err == nil {
				t.Fatal("reopened without a reason")
			}
			p, err := hs.SetCostPeriod(ctx, month, false, "admin", "late invoice", at.Add(time.Hour))
			if err != nil || p.Closed || p.ReopenReason != "late invoice" || p.ReopenedBy != "admin" {
				t.Fatalf("reopen: %+v %v", p, err)
			}
			if p := state(at.Add(48 * time.Hour)); p.Closed {
				t.Fatalf("a reopened month closed by itself: %+v", p)
			}
			p, err = hs.SetCostPeriod(ctx, month, true, "admin", "", at.Add(72*time.Hour))
			if err != nil || !p.Closed || p.ClosedBy != "admin" || p.ReopenReason != "late invoice" {
				t.Fatalf("close: %+v %v", p, err)
			}
		})
	}
}

// SPL-5433: an hr line carries its person, component, source, account, kind
// and correction; a cloud line carries none; a person needs a component; a
// yearly line sits on January; an unknown component or person is refused.
func TestCostEntryHRFields(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ce, hs := st.(CostEntryStore), st.(HRCostStore)
			p, err := hs.CreateHRPerson(ctx, HRPerson{Code: "F-" + digitsOf(uid("")), Name: "FirstName LastName", EmploymentType: "hourly", CreatedBy: "op"})
			if err != nil {
				t.Fatal(err)
			}
			by := uid("op-")
			line := CostEntry{Type: "hr", Label: p.Code + " hourly pay", Amount: 1200, Currency: "EUR", Period: "2026-10", CreatedBy: by,
				PersonID: p.ID, Component: "hourly_pay", Source: "payslip 2026-10", Account: "5000", CorrectsPeriod: "2026-08"}
			got, err := ce.CreateCostEntry(ctx, line)
			if err != nil || got.PersonID != p.ID || got.Component != "hourly_pay" || got.Source != "payslip 2026-10" || got.Account != "5000" ||
				got.PeriodKind != "month" || got.CorrectsPeriod != "2026-08" {
				t.Fatalf("hr line: %+v %v", got, err)
			}
			year, err := ce.CreateCostEntry(ctx, CostEntry{Type: "hr", Label: "YEL 2026", Amount: 5000, Currency: "EUR", Period: "2026-01", CreatedBy: by,
				Component: "yel", PeriodKind: "year", Source: "ledger"})
			if err != nil || year.PeriodKind != "year" || year.PersonID != "" {
				t.Fatalf("year line: %+v %v", year, err)
			}
			cloud, err := ce.CreateCostEntry(ctx, CostEntry{Type: "cloud", Label: "prd", Amount: 1, Currency: "EUR", Period: "2026-10", CreatedBy: by})
			if err != nil || cloud.PeriodKind != "" || cloud.Component != "" {
				t.Fatalf("cloud line: %+v %v", cloud, err)
			}
			if CostLockMonth(year) != "2026-12" || CostLockMonth(got) != "2026-10" {
				t.Errorf("lock months: %s %s", CostLockMonth(year), CostLockMonth(got))
			}
			base := CostEntry{Type: "hr", Label: "x", Amount: 1, Currency: "EUR", Period: "2026-10", CreatedBy: by}
			for why, mod := range map[string]func(*CostEntry){
				"cloud with a component": func(e *CostEntry) { e.Type, e.Component = "cloud", "bonus" },
				"person, no component":   func(e *CostEntry) { e.PersonID = p.ID },
				"year off January":       func(e *CostEntry) { e.PeriodKind = "year" },
				"bad kind":               func(e *CostEntry) { e.PeriodKind = "week" },
				"correction after":       func(e *CostEntry) { e.CorrectsPeriod = "2026-11" },
				"unknown component":      func(e *CostEntry) { e.Component = "no_such_thing" },
				"unknown person":         func(e *CostEntry) { e.PersonID, e.Component = "00000000-0000-4000-8000-000000000000", "bonus" },
			} {
				e := base
				mod(&e)
				if _, err := ce.CreateCostEntry(ctx, e); err == nil {
					t.Errorf("%s: stored", why)
				}
			}
		})
	}
}

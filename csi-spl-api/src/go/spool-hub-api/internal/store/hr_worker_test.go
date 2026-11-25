package store

import (
	"context"
	"crypto/rand"
	"errors"
	"fmt"
	"math/big"
	"testing"

	"github.com/jackc/pgx/v5"
)

// SPL-5433 step d: made-up people, lines, bands, cards and payslips only.

func hrF(v float64) *float64 { return &v }

func hrWorkerBands(year int) []HRWorkerRate {
	return []HRWorkerRate{
		{Year: year, Kind: "tyel_employee", AgeFrom: 17, AgeTo: 52, RatePct: 7, SetBy: "op"},
		{Year: year, Kind: "tyel_employee", AgeFrom: 53, AgeTo: 62, RatePct: 8.5, SetBy: "op"},
		{Year: year, Kind: "unemployment_employee", AgeFrom: 17, AgeTo: 64, RatePct: 1, SetBy: "op"},
	}
}

// The shares follow the age band; the tax is base % under the card's limit
// and extra % above it, counted over the year-to-date gross; net is gross
// minus both; an owner gets tax but no share, a contractor neither.
func TestComputeHRWorkerSide(t *testing.T) {
	people := []HRPerson{
		{ID: "p1", Code: "E-01", EmploymentType: "employee", BirthYear: 1990},
		{ID: "p2", Code: "E-02", EmploymentType: "employee", BirthYear: 1970},
		{ID: "p3", Code: "E-03", EmploymentType: "owner_management", BirthYear: 1980},
		{ID: "p4", Code: "E-04", EmploymentType: "contractor"},
	}
	lines := []CostEntry{
		hrLine("p1", "monthly_salary", 4000, "payslip"),
		hrLine("p2", "monthly_salary", 3000, "payslip"),
		hrLine("p3", "owner_salary", 2000, ""),
		hrLine("p4", "hourly_pay", 1000, ""),
	}
	// p1 earned 9 x 4000 = 36000 before October; p2's earlier income is in
	// another year (left out) and one yearly line (left out).
	for _, m := range []string{"2026-01", "2026-02", "2026-03", "2026-04", "2026-05", "2026-06", "2026-07", "2026-08", "2026-09"} {
		e := hrLine("p1", "monthly_salary", 4000, "")
		e.Period = m
		lines = append(lines, e)
	}
	old := hrLine("p2", "monthly_salary", 99999, "")
	old.Period = "2025-10"
	yearly := hrLine("p1", "bonus", 5000, "")
	yearly.Period, yearly.PeriodKind = "2026-01", "year"
	benefit := hrLine("p1", "lunch_benefit", 100, "")
	benefit.Period = "2026-03"
	lines = append(lines, old, yearly, benefit)
	p := ComputeHRPayroll("2026-10", people, lines, nil, DefaultHRComponents)
	ytd := HRYearToDate("2026-10", lines, DefaultHRComponents)
	if ytd[[2]string{"p1", "EUR"}] != 36000 || ytd[[2]string{"p2", "EUR"}] != 0 {
		t.Fatalf("ytd: %+v", ytd)
	}
	cards := []HRTaxCard{
		{PersonID: "p1", Year: 2026, BasePct: 20, ExtraPct: 40, IncomeLimit: 38000},
		{PersonID: "p3", Year: 2026, BasePct: 10, ExtraPct: 30, IncomeLimit: 50000},
		{PersonID: "p2", Year: 2025, BasePct: 99, ExtraPct: 99, IncomeLimit: 0},
	}
	ws := ComputeHRWorker(p, people, ytd, hrWorkerBands(2026), cards, nil)
	if len(ws) != 4 {
		t.Fatalf("worker rows: %+v", ws)
	}
	w1, w2, w3, w4 := ws[0], ws[1], ws[2], ws[3]
	// p1, age 36: tyel 7% = 280, unemployment 1% = 40; tax 2000 x 20% + 2000 x 40% = 1200; net 4000 - 320 - 1200
	if w1.Age != 36 || w1.YTDBefore != 36000 || w1.YTD != 40000 || len(w1.Shares) != 2 ||
		w1.Shares[0].Computed != 280 || w1.Shares[1].Computed != 40 || w1.Tax.Computed != 1200 || w1.Net.Computed != 2480 ||
		w1.Flags != 0 || len(w1.Missing) != 0 {
		t.Errorf("E-01: %+v", w1)
	}
	// p2, age 56: tyel 8.5% = 255, unemployment 30; 2025's card is not 2026's
	if w2.Shares[0].Computed != 255 || w2.Shares[1].Computed != 30 || w2.TaxCard != nil || w2.Tax.Computed != 0 ||
		len(w2.Missing) != 1 || w2.Missing[0] != "tax_card" || w2.Net.Computed != 2715 {
		t.Errorf("E-02: %+v", w2)
	}
	if len(w3.Shares) != 0 || w3.Tax.Computed != 200 || w3.Net.Computed != 1800 {
		t.Errorf("E-03 (owner: tax, no share): %+v", w3)
	}
	if len(w4.Shares) != 0 || w4.Tax.Computed != 0 || w4.Net.Computed != 1000 || len(w4.Missing) != 0 {
		t.Errorf("E-04 (contractor: neither): %+v", w4)
	}
	// The worker side never changes the employer side's cost.
	if p.Totals[0].Cost != 10000 {
		t.Errorf("cost total %v, want 10000 (gross only, no rate)", p.Totals[0].Cost)
	}
}

// A payslip value wins; a difference beyond a cent is flagged; the net is
// computed from the values that count, so it flags only its own difference;
// no birth year leaves both age-banded shares uncomputed and says so once.
func TestComputeHRWorkerPayslipCheck(t *testing.T) {
	people := []HRPerson{{ID: "p1", Code: "E-01", EmploymentType: "employee", BirthYear: 1990}, {ID: "p2", Code: "E-02", EmploymentType: "hourly"}}
	lines := []CostEntry{hrLine("p1", "monthly_salary", 4000, "payslip"), hrLine("p2", "hourly_pay", 1000, "")}
	p := ComputeHRPayroll("2026-10", people, lines, nil, DefaultHRComponents)
	cards := []HRTaxCard{{PersonID: "p1", Year: 2026, BasePct: 20, ExtraPct: 40, IncomeLimit: 100000}}
	slips := []HRPayslip{
		{PersonID: "p1", Month: "2026-10", Currency: "EUR", TyelEmployee: hrF(280.01), TaxWithheld: hrF(812), NetPay: hrF(2868)},
		{PersonID: "p1", Month: "2026-09", Currency: "EUR", NetPay: hrF(1)},
	}
	ws := ComputeHRWorker(p, people, nil, hrWorkerBands(2026), cards, slips)
	w := ws[0]
	// tyel 280.01 vs 280: within a cent; tax 812 vs 800: flagged; net 4000 - 280.01 - 40 - 812 = 2867.99 vs 2868: within a cent
	if w.Shares[0].Typed == nil || w.Shares[0].Flag != "" || w.Tax.Flag != "diff" || w.Tax.Diff != 12 || w.Tax.Amount != 812 ||
		w.Net.Computed != 2867.99 || w.Net.Flag != "" || w.Flags != 1 {
		t.Errorf("payslip check: %+v", w)
	}
	w2 := ws[1]
	if len(w2.Missing) != 2 || w2.Missing[0] != "birth_year" || w2.Missing[1] != "tax_card" || w2.Shares[0].RatePct != nil || w2.Shares[1].Computed != 0 || w2.Net.Computed != 1000 {
		t.Errorf("no birth year: %+v", w2)
	}
}

// Over the limit already: every euro is at the extra %; a month across the
// limit splits.
func TestHRTaxWithheld(t *testing.T) {
	c := HRTaxCard{BasePct: 10, ExtraPct: 50, IncomeLimit: 1000}
	for _, tc := range []struct{ gross, before, want float64 }{
		{500, 0, 50}, {500, 800, 20 + 150}, {500, 1000, 250}, {500, 5000, 250}, {0, 0, 0},
	} {
		if got := HRTaxWithheld(tc.gross, tc.before, c); got != tc.want {
			t.Errorf("tax(%v after %v) = %v, want %v", tc.gross, tc.before, got, tc.want)
		}
	}
}

func TestCheckHRWorkerInputs(t *testing.T) {
	ok := hrWorkerBands(2026)[:2]
	if why := CheckHRWorkerRates(2026, "tyel_employee", ok); why != "" {
		t.Errorf("good bands refused: %s", why)
	}
	if why := CheckHRWorkerRates(2026, "tyel_employee", nil); why != "" {
		t.Errorf("no bands (remove all) refused: %s", why)
	}
	overlap := []HRWorkerRate{ok[0], ok[1]}
	overlap[1].AgeFrom = 52
	for name, why := range map[string]string{
		"kind":    CheckHRWorkerRates(2026, "tax", ok),
		"year":    CheckHRWorkerRates(1999, "tyel_employee", ok),
		"overlap": CheckHRWorkerRates(2026, "tyel_employee", overlap),
		"mixed":   CheckHRWorkerRates(2027, "tyel_employee", ok),
	} {
		if why == "" {
			t.Errorf("%s: accepted", name)
		}
	}
	card := HRTaxCard{PersonID: "p", Year: 2026, BasePct: 20.5, ExtraPct: 40, IncomeLimit: 30000.5, SetBy: "op"}
	if why := CheckHRTaxCard(card); why != "" {
		t.Errorf("good card refused: %s", why)
	}
	bad := card
	bad.BasePct = 20.555
	if CheckHRTaxCard(bad) == "" {
		t.Error("3-decimal base_pct accepted")
	}
	slip := HRPayslip{PersonID: "p", Month: "2026-10", Currency: "EUR", NetPay: hrF(-5), SetBy: "op"}
	if why := CheckHRPayslip(slip); why != "" {
		t.Errorf("negative net (a correction) refused: %s", why)
	}
	slip.TaxWithheld = hrF(-1)
	if CheckHRPayslip(slip) == "" {
		t.Error("negative tax accepted")
	}
	if CheckHRPayslip(HRPayslip{PersonID: "p", Month: "2026-10", Currency: "EUR", SetBy: "op"}) == "" {
		t.Error("an empty payslip accepted")
	}
}

func TestHRWorkerStore(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ws := st.(HRWorkerStore)
			hs := st.(HRCostStore)
			person, err := hs.CreateHRPerson(ctx, HRPerson{Code: hrTestCode('W'), Name: "FirstName LastName", EmploymentType: "employee", BirthYear: 1990, CreatedBy: "op"})
			if err != nil {
				t.Fatal(err)
			}
			n, err := rand.Int(rand.Reader, big.NewInt(101))
			if err != nil {
				t.Fatal(err)
			}
			year := 2000 + int(n.Int64())
			got, err := ws.SetHRWorkerRates(ctx, year, "tyel_employee", hrWorkerBands(year)[:2])
			if err != nil || len(got) != 2 || got[1].RatePct != 8.5 || got[0].SetAt.IsZero() {
				t.Fatalf("set bands: %+v %v", got, err)
			}
			if _, err := ws.SetHRWorkerRates(ctx, year, "tyel_employee", hrWorkerBands(year)[:1]); err != nil {
				t.Fatal(err)
			}
			if list, err := ws.ListHRWorkerRates(ctx, year); err != nil || len(list) != 1 || list[0].AgeTo != 52 {
				t.Errorf("replace bands: %+v %v", list, err)
			}
			if _, err := ws.SetHRWorkerRates(ctx, year, "tyel_employee", nil); err != nil {
				t.Fatal(err)
			}
			if list, _ := ws.ListHRWorkerRates(ctx, year); len(list) != 0 {
				t.Errorf("remove bands: %+v", list)
			}

			card := HRTaxCard{PersonID: person.ID, Year: year, BasePct: 20, ExtraPct: 40, IncomeLimit: 30000, Source: "made-up", SetBy: "op"}
			if c, err := ws.SetHRTaxCard(ctx, card); err != nil || c.IncomeLimit != 30000 || c.SetAt.IsZero() {
				t.Fatalf("set card: %+v %v", c, err)
			}
			card.BasePct = 21.5
			if _, err := ws.SetHRTaxCard(ctx, card); err != nil {
				t.Fatal(err)
			}
			cards, err := ws.ListHRTaxCards(ctx, year)
			if err != nil || len(cards) == 0 {
				t.Fatalf("list cards: %+v %v", cards, err)
			}
			found := false
			for _, c := range cards {
				found = found || (c.PersonID == person.ID && c.BasePct == 21.5)
			}
			if !found {
				t.Errorf("replaced card not listed: %+v", cards)
			}
			ghost := card
			ghost.PersonID = "00000000-0000-4000-8000-000000000000"
			if _, err := ws.SetHRTaxCard(ctx, ghost); !errors.Is(err, ErrNotFound) {
				t.Errorf("card of no person: %v, want ErrNotFound", err)
			}

			month := fmt.Sprintf("%04d-10", year)
			slip := HRPayslip{PersonID: person.ID, Month: month, Currency: "EUR", TaxWithheld: hrF(812.5), NetPay: hrF(2868), SetBy: "op"}
			if s, err := ws.SetHRPayslip(ctx, slip); err != nil || s.TaxWithheld == nil || *s.TaxWithheld != 812.5 || s.TyelEmployee != nil {
				t.Fatalf("set payslip: %+v %v", s, err)
			}
			slips, err := ws.ListHRPayslips(ctx, month)
			if err != nil || len(slips) == 0 {
				t.Fatalf("list payslips: %+v %v", slips, err)
			}
			if err := ws.DeleteHRPayslip(ctx, person.ID, month, "EUR"); err != nil {
				t.Fatal(err)
			}
			if err := ws.DeleteHRPayslip(ctx, person.ID, month, "EUR"); !errors.Is(err, ErrNotFound) {
				t.Errorf("second payslip delete: %v, want ErrNotFound", err)
			}
			if err := ws.DeleteHRTaxCard(ctx, person.ID, year); err != nil {
				t.Fatal(err)
			}
			if err := ws.DeleteHRTaxCard(ctx, person.ID, year); !errors.Is(err, ErrNotFound) {
				t.Errorf("second card delete: %v, want ErrNotFound", err)
			}
		})
	}
}

// The tax card and payslip tables' policy hides them unless app.costs_names
// is on, even in the operator scope, like the names.
func TestHRWorkerTablesNeedTheFlag(t *testing.T) {
	ctx := context.Background()
	pg, ok := drivers(t)["postgres"].(*Postgres)
	if !ok {
		t.Skip("no SPOOL_TEST_PG_DSN")
	}
	person, err := pg.CreateHRPerson(ctx, HRPerson{Code: hrTestCode('T'), Name: "FirstName LastName", EmploymentType: "employee", CreatedBy: "op"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pg.SetHRTaxCard(ctx, HRTaxCard{PersonID: person.ID, Year: 2030, BasePct: 10, ExtraPct: 20, IncomeLimit: 1000, SetBy: "op"}); err != nil {
		t.Fatal(err)
	}
	if _, err := pg.SetHRPayslip(ctx, HRPayslip{PersonID: person.ID, Month: "2030-01", Currency: "EUR", NetPay: hrF(1), SetBy: "op"}); err != nil {
		t.Fatal(err)
	}
	for _, table := range []string{"hr_tax_cards", "hr_payslips"} {
		var without, with int
		if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
			if err := tx.QueryRow(ctx, `SELECT count(*) FROM `+table).Scan(&without); err != nil {
				return err
			}
			if _, err := tx.Exec(ctx, pgCostsNames); err != nil {
				return err
			}
			return tx.QueryRow(ctx, `SELECT count(*) FROM `+table).Scan(&with)
		}); err != nil {
			t.Fatal(err)
		}
		if without != 0 || with == 0 {
			t.Errorf("%s visible without the flag: %d, with it: %d; want 0 and > 0", table, without, with)
		}
	}
}

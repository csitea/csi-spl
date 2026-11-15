package store

import (
	"context"
	"math"
	"slices"
	"sort"
	"strings"
	"time"
	"unicode/utf8"
)

// The worker side of a person's month (SPL-5433 step d, rdb 0285, spec 123
// section 16.5; owner HUM-10, t1 2d974709, poll 2ff12c21 answer 4 B). For each
// person and month the hub computes the employee's statutory shares (TyEL by
// age band, unemployment), the tax withheld from the person's tax card with
// the running year-to-date gross, and the net pay. A value typed from the
// payslip wins and a difference above a cent is flagged.
//
// The worker side is part of the gross (owner Q5 A: management reporting):
// it is never written to a cost line, never added to a report or a total, and
// only a costs.write caller sees it (tax cards and payslips are personal,
// their tables' policy asks app.costs_names like hr_person_names).

// HRWorkerKinds are rdb 0285's hr_worker_rates.kind CHECK.
var HRWorkerKinds = []string{"tyel_employee", "unemployment_employee"}

// HRWorkerTypes are the employment types the employee's statutory shares
// apply to: an owner in management pays YEL (typed as a line) and a
// contractor invoices.
var HRWorkerTypes = []string{"employee", "hourly"}

// HRTaxedTypes are the employment types tax is withheld from: a contractor
// invoices and pays their own tax.
var HRTaxedTypes = []string{"employee", "hourly", "owner_management"}

// hrMaxWorkerBands caps the age bands of one year and kind.
const hrMaxWorkerBands = 10

// HRWorkerRate is one row of hr_worker_rates: the employee's share of kind
// for one year, for ages AgeFrom..AgeTo that year.
type HRWorkerRate struct {
	Year    int       `json:"year"`
	Kind    string    `json:"kind"`
	AgeFrom int       `json:"age_from"`
	AgeTo   int       `json:"age_to"`
	RatePct float64   `json:"rate_pct"`
	Source  string    `json:"source"`
	SetBy   string    `json:"set_by"`
	SetAt   time.Time `json:"set_at"`
}

// hr4Decimals is whether v has at most 4 decimals.
func hr4Decimals(v float64) bool { return math.Abs(v*1e4-math.Round(v*1e4)) <= 1e-6 }

// hr2Decimals is whether v has at most 2 decimals (cents).
func hr2Decimals(v float64) bool { return math.Abs(v*100-math.Round(v*100)) <= 1e-6 }

// CheckHRWorkerRates names the first thing the bands of one year and kind may
// not carry ("" = fine): rdb 0285's CHECKs, at most 10 bands, no two bands
// overlapping. An empty list is fine: it removes the year's bands of kind.
func CheckHRWorkerRates(year int, kind string, bands []HRWorkerRate) string {
	switch {
	case year < 2000 || year > 2100:
		return "year must be between 2000 and 2100"
	case !slices.Contains(HRWorkerKinds, kind):
		return "kind must be tyel_employee or unemployment_employee"
	case len(bands) > hrMaxWorkerBands:
		return "at most 10 age bands"
	}
	sorted := slices.Clone(bands)
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].AgeFrom < sorted[j].AgeFrom })
	for i, b := range sorted {
		switch {
		case b.Year != year || b.Kind != kind:
			return "every band must carry the year and kind of the path"
		case b.AgeFrom < 0 || b.AgeTo > 120 || b.AgeTo < b.AgeFrom:
			return "age_from..age_to must be a range within 0..120"
		case i > 0 && b.AgeFrom <= sorted[i-1].AgeTo:
			return "age bands must not overlap"
		case math.IsNaN(b.RatePct) || b.RatePct < 0 || b.RatePct >= 100:
			return "rate_pct must be a percent from 0 to below 100"
		case !hr4Decimals(b.RatePct):
			return "rate_pct takes at most 4 decimals"
		case utf8.RuneCountInString(b.Source) > 200:
			return "source must be at most 200 characters"
		case strings.TrimSpace(b.SetBy) == "" || len(b.SetBy) > 200:
			return "set_by must be 1..200 characters"
		}
	}
	return ""
}

// HRTaxCard is one row of hr_tax_cards: BasePct of the year's income up to
// IncomeLimit, ExtraPct above it.
type HRTaxCard struct {
	PersonID    string    `json:"person_id"`
	Year        int       `json:"year"`
	BasePct     float64   `json:"base_pct"`
	ExtraPct    float64   `json:"extra_pct"`
	IncomeLimit float64   `json:"income_limit"`
	Source      string    `json:"source"`
	SetBy       string    `json:"set_by"`
	SetAt       time.Time `json:"set_at"`
}

// CheckHRTaxCard names the first thing c may not carry ("" = fine): rdb
// 0285's CHECKs.
func CheckHRTaxCard(c HRTaxCard) string {
	switch {
	case strings.TrimSpace(c.PersonID) == "":
		return "person_id is required"
	case c.Year < 2000 || c.Year > 2100:
		return "year must be between 2000 and 2100"
	case math.IsNaN(c.BasePct) || c.BasePct < 0 || c.BasePct >= 100 || !hr2Decimals(c.BasePct):
		return "base_pct must be a percent from 0 to below 100, at most 2 decimals"
	case math.IsNaN(c.ExtraPct) || c.ExtraPct < 0 || c.ExtraPct >= 100 || !hr2Decimals(c.ExtraPct):
		return "extra_pct must be a percent from 0 to below 100, at most 2 decimals"
	case math.IsNaN(c.IncomeLimit) || c.IncomeLimit < 0 || c.IncomeLimit >= 1e10 || !hr2Decimals(c.IncomeLimit):
		return "income_limit must be 0 or more, in cents"
	case utf8.RuneCountInString(c.Source) > 200:
		return "source must be at most 200 characters"
	case strings.TrimSpace(c.SetBy) == "" || len(c.SetBy) > 200:
		return "set_by must be 1..200 characters"
	}
	return ""
}

// HRPayslip is one row of hr_payslips: the worker-side values one payslip
// carries, each nil when it does not.
type HRPayslip struct {
	PersonID             string    `json:"person_id"`
	Month                string    `json:"month"`
	Currency             string    `json:"currency"`
	TyelEmployee         *float64  `json:"tyel_employee,omitempty"`
	UnemploymentEmployee *float64  `json:"unemployment_employee,omitempty"`
	TaxWithheld          *float64  `json:"tax_withheld,omitempty"`
	NetPay               *float64  `json:"net_pay,omitempty"`
	SetBy                string    `json:"set_by"`
	SetAt                time.Time `json:"set_at"`
}

// value is the payslip's typed value of kind, nil when none.
func (p HRPayslip) value(kind string) *float64 {
	switch kind {
	case "tyel_employee":
		return p.TyelEmployee
	case "unemployment_employee":
		return p.UnemploymentEmployee
	case "tax_withheld":
		return p.TaxWithheld
	case "net_pay":
		return p.NetPay
	}
	return nil
}

// CheckHRPayslip names the first thing p may not carry ("" = fine): rdb
// 0285's CHECKs, and at least one value.
func CheckHRPayslip(p HRPayslip) string {
	switch {
	case strings.TrimSpace(p.PersonID) == "":
		return "person_id is required"
	case !IsCostMonth(p.Month):
		return "month must be YYYY-MM"
	case !IsCurrencyCode(p.Currency):
		return "currency must be 3 capital letters, e.g. EUR"
	case p.TyelEmployee == nil && p.UnemploymentEmployee == nil && p.TaxWithheld == nil && p.NetPay == nil:
		return "a payslip carries at least one of tyel_employee, unemployment_employee, tax_withheld, net_pay"
	case strings.TrimSpace(p.SetBy) == "" || len(p.SetBy) > 200:
		return "set_by must be 1..200 characters"
	}
	for _, k := range []string{"tyel_employee", "unemployment_employee", "tax_withheld", "net_pay"} {
		v := p.value(k)
		if v == nil {
			continue
		}
		if math.IsNaN(*v) || math.Abs(*v) >= 1e10 || !hr2Decimals(*v) {
			return k + " must be an amount in cents"
		}
		if *v < 0 && k != "net_pay" {
			return k + " must be 0 or more"
		}
	}
	return ""
}

// HRWorkerStore is the store half of rdb 0285. Optional, like HRRateStore.
// The tax card and payslip calls are a costs.write caller's only: on Postgres
// they set app.costs_names in their transaction.
type HRWorkerStore interface {
	// ListHRWorkerRates is year's bands by kind, then age_from.
	ListHRWorkerRates(ctx context.Context, year int) ([]HRWorkerRate, error)
	// SetHRWorkerRates replaces year's bands of kind with checked bands
	// (none = remove them all) and answers what it stored.
	SetHRWorkerRates(ctx context.Context, year int, kind string, bands []HRWorkerRate) ([]HRWorkerRate, error)
	// ListHRTaxCards is year's tax cards.
	ListHRTaxCards(ctx context.Context, year int) ([]HRTaxCard, error)
	// SetHRTaxCard stores a checked card, replacing the person's card of its
	// year; ErrNotFound when the person is not there.
	SetHRTaxCard(ctx context.Context, c HRTaxCard) (HRTaxCard, error)
	// DeleteHRTaxCard removes a card; ErrNotFound when none.
	DeleteHRTaxCard(ctx context.Context, personID string, year int) error
	// ListHRPayslips is month's payslips.
	ListHRPayslips(ctx context.Context, month string) ([]HRPayslip, error)
	// SetHRPayslip stores a checked payslip, replacing the person's payslip
	// of its month and currency; ErrNotFound when the person is not there.
	SetHRPayslip(ctx context.Context, p HRPayslip) (HRPayslip, error)
	// DeleteHRPayslip removes a payslip; ErrNotFound when none.
	DeleteHRPayslip(ctx context.Context, personID, month, currency string) error
}

// HRWorkerLine is one computed worker-side value, checked against the
// payslip. Amount is what counts: the typed value, else the computed one.
type HRWorkerLine struct {
	Kind     string   `json:"kind"`
	RatePct  *float64 `json:"rate_pct,omitempty"`
	Computed float64  `json:"computed"`
	Typed    *float64 `json:"typed,omitempty"`
	Amount   float64  `json:"amount"`
	// Diff is Typed minus Computed, when both are there.
	Diff float64 `json:"diff"`
	// Flag: "" fine, "diff" the payslip differs from the calculation.
	Flag string `json:"flag,omitempty"`
}

// HRWorkerSide is one person's worker side of a month in one currency.
type HRWorkerSide struct {
	PersonID string `json:"person_id"`
	Code     string `json:"code"`
	Currency string `json:"currency"`
	// Age is the person's age in the month's year, 0 when no birth year.
	Age   int     `json:"age,omitempty"`
	Gross float64 `json:"gross"`
	// YTDBefore is the gross of the year's earlier months in this currency,
	// YTD the same with this month.
	YTDBefore float64 `json:"ytd_before"`
	YTD       float64 `json:"ytd"`
	// TaxCard is the year's card, nil when none is typed.
	TaxCard *HRTaxCard     `json:"tax_card,omitempty"`
	Shares  []HRWorkerLine `json:"shares"`
	Tax     HRWorkerLine   `json:"tax"`
	Net     HRWorkerLine   `json:"net"`
	// Missing names what the calculation lacks: "tax_card", "birth_year".
	Missing []string `json:"missing"`
	Flags   int      `json:"flags"`
}

// hrBandRate is the rate of kind for age in year's bands; false when no band
// holds it.
func hrBandRate(rates []HRWorkerRate, year int, kind string, age int) (float64, bool) {
	for _, r := range rates {
		if r.Year == year && r.Kind == kind && age >= r.AgeFrom && age <= r.AgeTo {
			return r.RatePct, true
		}
	}
	return 0, false
}

// hrHasKind is whether year has any band of kind.
func hrHasKind(rates []HRWorkerRate, year int, kind string) bool {
	return slices.ContainsFunc(rates, func(r HRWorkerRate) bool { return r.Year == year && r.Kind == kind })
}

// hrCheckLine sets l's typed value from the payslip and flags a difference
// beyond a cent.
func hrCheckLine(l *HRWorkerLine, typed *float64) {
	l.Amount = l.Computed
	if typed == nil {
		return
	}
	v := hrCents(*typed)
	l.Typed, l.Amount = &v, v
	l.Diff = hrCents(v - l.Computed)
	if math.Abs(l.Diff) > hrDiffTolerance {
		l.Flag = "diff"
	}
}

// HRYearToDate is the gross of each (person, currency) over the monthly hr
// lines of month's year before month: the running income a tax card's limit
// is counted against.
func HRYearToDate(month string, lines []CostEntry, comps []HRComponent) map[[2]string]float64 {
	group := map[string]string{}
	for _, c := range comps {
		group[c.Component] = c.Group
	}
	from := month[:4] + "-01"
	out := map[[2]string]float64{}
	for _, e := range lines {
		if e.Type != "hr" || e.PersonID == "" || e.PeriodKind == "year" || e.Period < from || e.Period >= month {
			continue
		}
		if slices.Contains(HRGrossGroups, group[e.Component]) {
			k := [2]string{e.PersonID, e.Currency}
			out[k] = hrCents(out[k] + e.Amount)
		}
	}
	return out
}

// ComputeHRWorker is the worker side of every person in p (month's employer
// side, which carries each person's gross per currency): the shares by age
// band, the tax by the year's card over the year-to-date gross, the net, each
// checked against the month's payslip of that person and currency. Pure.
func ComputeHRWorker(p HRPayroll, people []HRPerson, ytd map[[2]string]float64, rates []HRWorkerRate, cards []HRTaxCard, slips []HRPayslip) []HRWorkerSide {
	who := map[string]HRPerson{}
	for _, x := range people {
		who[x.ID] = x
	}
	card := map[string]HRTaxCard{}
	for _, c := range cards {
		if c.Year == p.Year {
			card[c.PersonID] = c
		}
	}
	slip := map[[2]string]HRPayslip{}
	for _, s := range slips {
		if s.Month == p.Month {
			slip[[2]string{s.PersonID, s.Currency}] = s
		}
	}
	out := []HRWorkerSide{}
	for _, row := range p.People {
		person := who[row.PersonID]
		k := [2]string{row.PersonID, row.Currency}
		c, hasCard := card[row.PersonID]
		w := hrWorkerRow(p.Year, row, person, ytd[k], rates, c, hasCard, slip[k])
		out = append(out, w)
	}
	return out
}

// hrWorkerRow is one person's worker side in one currency.
func hrWorkerRow(year int, row HRPayrollPerson, person HRPerson, ytdBefore float64, rates []HRWorkerRate, c HRTaxCard, hasCard bool, s HRPayslip) HRWorkerSide {
	w := HRWorkerSide{PersonID: row.PersonID, Code: row.Code, Currency: row.Currency, Gross: row.Gross,
		YTDBefore: hrCents(ytdBefore), YTD: hrCents(ytdBefore + row.Gross), Shares: []HRWorkerLine{}, Missing: []string{}}
	if person.BirthYear > 0 {
		w.Age = year - person.BirthYear
	}
	shares := 0.0
	if slices.Contains(HRWorkerTypes, row.EmploymentType) {
		for _, kind := range HRWorkerKinds {
			if !hrHasKind(rates, year, kind) {
				continue
			}
			l := HRWorkerLine{Kind: kind}
			if w.Age == 0 {
				// Both shares go by age band: no birth year, no share.
				if !slices.Contains(w.Missing, "birth_year") {
					w.Missing = append(w.Missing, "birth_year")
				}
			} else if pct, ok := hrBandRate(rates, year, kind, w.Age); ok {
				v := pct
				l.RatePct = &v
				l.Computed = hrCents(row.Gross * pct / 100)
			}
			hrCheckLine(&l, s.value(kind))
			shares += l.Amount
			w.Shares = append(w.Shares, l)
		}
	}
	w.Tax = HRWorkerLine{Kind: "tax_withheld"}
	if slices.Contains(HRTaxedTypes, row.EmploymentType) {
		if hasCard {
			cc := c
			w.TaxCard = &cc
			w.Tax.Computed = HRTaxWithheld(row.Gross, ytdBefore, c)
		} else {
			w.Missing = append(w.Missing, "tax_card")
		}
	}
	hrCheckLine(&w.Tax, s.value("tax_withheld"))
	w.Net = HRWorkerLine{Kind: "net_pay", Computed: hrCents(row.Gross - shares - w.Tax.Amount)}
	hrCheckLine(&w.Net, s.value("net_pay"))
	for _, l := range append(slices.Clone(w.Shares), w.Tax, w.Net) {
		if l.Flag != "" {
			w.Flags++
		}
	}
	return w
}

// HRTaxWithheld is the tax on a month's gross by card c, when ytdBefore of
// the year's income came before it: BasePct on the part still under the
// card's income limit, ExtraPct on the part above it.
func HRTaxWithheld(gross, ytdBefore float64, c HRTaxCard) float64 {
	under := math.Max(0, math.Min(gross, c.IncomeLimit-ytdBefore))
	over := gross - under
	return hrCents(under*c.BasePct/100 + over*c.ExtraPct/100)
}

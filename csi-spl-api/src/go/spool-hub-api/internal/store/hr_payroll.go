package store

import (
	"context"
	"fmt"
	"math"
	"slices"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// The employer side of human costs (SPL-5433 step c, rdb 0284, spec 123
// section 16.4; owner HUM-10, t1 2d974709, poll 2ff12c21 answer 4 B). For each
// person and month the hub computes every rated employer contribution as
// gross x the year's rate. A typed line of that component (a payslip's value)
// wins, and a difference from the computed amount is flagged. A booked line
// (source HRComputedSource...) is the computed amount written into the books
// so the cost reports carry it; it is flagged stale when the calculation has
// moved since. The worker side (tax cards, employee shares, net pay) is step d.

// HRGrossGroups are the groups whose lines make a person's gross pay, the
// base every rate multiplies. Benefits, training and travel are costs but no
// pay a contribution is levied on.
var HRGrossGroups = []string{"salaries_wages", "working_time_allowances", "bonuses_incentives", "leave_absence"}

// HREmployerGroup is the group of the components a rate computes.
const HREmployerGroup = "employer_contributions"

// HRComputedSource starts the source of a line the hub booked from the
// calculation; any other source is a typed value.
const HRComputedSource = "computed:"

// hrDiffTolerance is the largest difference between a typed and a computed
// amount that is not flagged: one cent, as both are rounded to cents.
const hrDiffTolerance = 0.011

// HRRate is one row of hr_rates.
type HRRate struct {
	Year      int       `json:"year"`
	Component string    `json:"component"`
	RatePct   float64   `json:"rate_pct"`
	AppliesTo []string  `json:"applies_to"`
	Source    string    `json:"source"`
	SetBy     string    `json:"set_by"`
	SetAt     time.Time `json:"set_at"`
}

// CheckHRRate names the first thing r may not carry ("" = fine): rdb 0284's
// CHECKs, plus that component is an employer contribution levied on gross
// (comps = the components the store holds).
func CheckHRRate(r HRRate, comps []HRComponent) string {
	i := slices.IndexFunc(comps, func(c HRComponent) bool { return c.Component == r.Component })
	switch {
	case r.Year < 2000 || r.Year > 2100:
		return "year must be between 2000 and 2100"
	case i < 0 || comps[i].Group != HREmployerGroup:
		return "component must be an employer contribution, e.g. tyel_employer"
	case r.Component == "yel":
		return "yel is the entrepreneur's own pension, not a share of gross; type it as a line"
	case math.IsNaN(r.RatePct) || r.RatePct < 0 || r.RatePct >= 100:
		return "rate_pct must be a percent from 0 to below 100"
	case math.Abs(r.RatePct*1e4-math.Round(r.RatePct*1e4)) > 1e-6:
		return "rate_pct takes at most 4 decimals"
	case len(r.AppliesTo) == 0 || len(r.AppliesTo) > len(HREmploymentTypes):
		return "applies_to must name 1..4 employment types"
	case utf8.RuneCountInString(r.Source) > 200:
		return "source must be at most 200 characters"
	case strings.TrimSpace(r.SetBy) == "" || len(r.SetBy) > 200:
		return "set_by must be 1..200 characters"
	}
	seen := map[string]bool{}
	for _, t := range r.AppliesTo {
		if !slices.Contains(HREmploymentTypes, t) || seen[t] {
			return "applies_to must name distinct employment types: employee, hourly, owner_management, contractor"
		}
		seen[t] = true
	}
	return ""
}

// HRRateStore is the store half of rdb 0284. Optional, like HRCostStore.
type HRRateStore interface {
	// ListHRRates is year's rates by component.
	ListHRRates(ctx context.Context, year int) ([]HRRate, error)
	// SetHRRate stores a checked rate, replacing the year's row of its
	// component, and answers it.
	SetHRRate(ctx context.Context, r HRRate) (HRRate, error)
	// DeleteHRRate removes year's rate of component; ErrNotFound when none.
	DeleteHRRate(ctx context.Context, year int, component string) error
}

// HRPayrollLine is one employer contribution of one person and month.
// Amount is what counts: the typed value, else the booked one, else the
// computed one.
type HRPayrollLine struct {
	Component string   `json:"component"`
	RatePct   *float64 `json:"rate_pct,omitempty"`
	Computed  float64  `json:"computed"`
	Typed     *float64 `json:"typed,omitempty"`
	Booked    *float64 `json:"booked,omitempty"`
	Amount    float64  `json:"amount"`
	// Diff is Typed (or Booked) minus Computed, when one is there and a rate
	// computes this component for the person.
	Diff float64 `json:"diff"`
	// Flag: "" fine, "diff" a typed value differs from the calculation,
	// "stale" a booked value the calculation has moved away from.
	Flag string `json:"flag,omitempty"`
}

// HRPayrollPerson is one person's month in one currency.
type HRPayrollPerson struct {
	PersonID       string          `json:"person_id"`
	Code           string          `json:"code"`
	EmploymentType string          `json:"employment_type"`
	Currency       string          `json:"currency"`
	Gross          float64         `json:"gross"`
	Employer       []HRPayrollLine `json:"employer"`
	EmployerTotal  float64         `json:"employer_total"`
	Other          float64         `json:"other"`
	Cost           float64         `json:"cost"`
	Flags          int             `json:"flags"`
}

// HRPayrollTotal is the month's sums in one currency.
type HRPayrollTotal struct {
	Currency      string  `json:"currency"`
	Gross         float64 `json:"gross"`
	EmployerTotal float64 `json:"employer_total"`
	Other         float64 `json:"other"`
	Cost          float64 `json:"cost"`
	ToBook        int     `json:"to_book"`
}

// HRPayroll is the employer side of one month.
type HRPayroll struct {
	Month  string            `json:"month"`
	Year   int               `json:"year"`
	Rates  []HRRate          `json:"rates"`
	People []HRPayrollPerson `json:"people"`
	Totals []HRPayrollTotal  `json:"totals"`
	Flags  int               `json:"flags"`
}

// HRBooking is one line the book action writes: person, component, currency
// and the computed amount.
type HRBooking struct {
	PersonID  string
	Component string
	Currency  string
	Amount    float64
}

// hrCents rounds v to cents, half away from zero.
func hrCents(v float64) float64 { return math.Round(v*100) / 100 }

// ComputeHRPayroll is month's employer side from the people, month's cost
// lines (every type; only the person's monthly hr lines count), the year's
// rates and the components. Pure: no store, no clock. A person with no line
// in month is left out; a yearly line (period_kind year) is not a month's.
func ComputeHRPayroll(month string, people []HRPerson, lines []CostEntry, rates []HRRate, comps []HRComponent) HRPayroll {
	year := hrPayrollYear(month)
	out := HRPayroll{Month: month, Year: year, Rates: rates, People: []HRPayrollPerson{}, Totals: []HRPayrollTotal{}}
	if out.Rates == nil {
		out.Rates = []HRRate{}
	}
	group := map[string]string{}
	order := map[string]int{}
	for _, c := range comps {
		group[c.Component], order[c.Component] = c.Group, c.SortOrder
	}
	who := map[string]HRPerson{}
	for _, p := range people {
		who[p.ID] = p
	}
	accs := hrAccumulate(month, lines, who, group)
	totals := map[string]*HRPayrollTotal{}
	var currencies []string
	for _, k := range hrSortedKeys(accs, who) {
		p := who[k.person]
		row, toBook := hrPersonRow(k.currency, p, accs[k], hrRatedFor(rates, year, p.EmploymentType), order)
		t := totals[k.currency]
		if t == nil {
			t = &HRPayrollTotal{Currency: k.currency}
			totals[k.currency] = t
			currencies = append(currencies, k.currency)
		}
		t.ToBook += toBook
		t.Gross, t.EmployerTotal = hrCents(t.Gross+row.Gross), hrCents(t.EmployerTotal+row.EmployerTotal)
		t.Other, t.Cost = hrCents(t.Other+row.Other), hrCents(t.Cost+row.Cost)
		out.Flags += row.Flags
		out.People = append(out.People, row)
	}
	sort.Strings(currencies)
	for _, c := range currencies {
		out.Totals = append(out.Totals, *totals[c])
	}
	return out
}

// hrPayrollYear is the year of a YYYY-MM month, 0 when it has none.
func hrPayrollYear(month string) int {
	year := 0
	if len(month) >= 4 {
		fmt.Sscanf(month[:4], "%d", &year)
	}
	return year
}

// hrPayKey is one person in one currency.
type hrPayKey struct{ person, currency string }

// hrPayAcc sums one person's month in one currency: gross, other costs, and
// the employer contributions typed by hand or booked by the calculation.
type hrPayAcc struct {
	gross, other   float64
	typed, booked  map[string]float64
	hasTyped, hasB map[string]bool
}

// add counts one hr line of component group g.
func (a *hrPayAcc) add(e CostEntry, g string) {
	switch {
	case slices.Contains(HRGrossGroups, g):
		a.gross += e.Amount
	case g == HREmployerGroup && strings.HasPrefix(e.Source, HRComputedSource):
		a.booked[e.Component] += e.Amount
		a.hasB[e.Component] = true
	case g == HREmployerGroup:
		a.typed[e.Component] += e.Amount
		a.hasTyped[e.Component] = true
	default:
		a.other += e.Amount
	}
}

// hrAccumulate sums month's monthly hr lines of known people per person and
// currency.
func hrAccumulate(month string, lines []CostEntry, who map[string]HRPerson, group map[string]string) map[hrPayKey]*hrPayAcc {
	accs := map[hrPayKey]*hrPayAcc{}
	for _, e := range lines {
		if e.Type != "hr" || e.PersonID == "" || e.Period != month || e.PeriodKind == "year" {
			continue
		}
		if _, ok := who[e.PersonID]; !ok {
			continue
		}
		k := hrPayKey{e.PersonID, e.Currency}
		a := accs[k]
		if a == nil {
			a = &hrPayAcc{typed: map[string]float64{}, booked: map[string]float64{}, hasTyped: map[string]bool{}, hasB: map[string]bool{}}
			accs[k] = a
		}
		a.add(e, group[e.Component])
	}
	return accs
}

// hrSortedKeys is accs' keys by person code, then currency.
func hrSortedKeys(accs map[hrPayKey]*hrPayAcc, who map[string]HRPerson) []hrPayKey {
	keys := make([]hrPayKey, 0, len(accs))
	for k := range accs {
		keys = append(keys, k)
	}
	sort.Slice(keys, func(i, j int) bool {
		ci, cj := who[keys[i].person].Code, who[keys[j].person].Code
		if ci != cj {
			return ci < cj
		}
		return keys[i].currency < keys[j].currency
	})
	return keys
}

// hrRatedFor is the year's rate per component for one employment type.
func hrRatedFor(rates []HRRate, year int, employmentType string) map[string]float64 {
	rated := map[string]float64{}
	for _, r := range rates {
		if r.Year == year && slices.Contains(r.AppliesTo, employmentType) {
			rated[r.Component] = r.RatePct
		}
	}
	return rated
}

// hrComponentNames is every employer component the person has a line or a
// rate for, in the components' sort order, then by name.
func hrComponentNames(a *hrPayAcc, rated map[string]float64, order map[string]int) []string {
	set := map[string]bool{}
	for c := range a.typed {
		set[c] = true
	}
	for c := range a.booked {
		set[c] = true
	}
	for c := range rated {
		set[c] = true
	}
	names := make([]string, 0, len(set))
	for c := range set {
		names = append(names, c)
	}
	sort.Slice(names, func(i, j int) bool {
		if order[names[i]] != order[names[j]] {
			return order[names[i]] < order[names[j]]
		}
		return names[i] < names[j]
	})
	return names
}

// hrPersonRow is one person's month in one currency, and how many of its
// lines are still to book.
func hrPersonRow(currency string, p HRPerson, a *hrPayAcc, rated map[string]float64, order map[string]int) (HRPayrollPerson, int) {
	row := HRPayrollPerson{PersonID: p.ID, Code: p.Code, EmploymentType: p.EmploymentType, Currency: currency,
		Gross: hrCents(a.gross), Other: hrCents(a.other), Employer: []HRPayrollLine{}}
	toBook := 0
	for _, c := range hrComponentNames(a, rated, order) {
		l, book := hrEmployerLine(c, row.Gross, a, rated)
		if book {
			toBook++
		}
		if l.Flag != "" {
			row.Flags++
		}
		row.EmployerTotal += l.Amount
		row.Employer = append(row.Employer, l)
	}
	row.EmployerTotal = hrCents(row.EmployerTotal)
	row.Cost = hrCents(row.Gross + row.EmployerTotal + row.Other)
	return row, toBook
}

// hrEmployerLine is component c of one person's month: computed from gross
// when rated, then the typed value (a difference flagged) or the booked one
// (stale flagged). book is true when only the calculation is there.
func hrEmployerLine(c string, gross float64, a *hrPayAcc, rated map[string]float64) (HRPayrollLine, bool) {
	l := HRPayrollLine{Component: c}
	pct, isRated := rated[c]
	if isRated {
		v := pct
		l.RatePct = &v
		l.Computed = hrCents(gross * pct / 100)
	}
	l.Amount = l.Computed
	switch {
	case a.hasTyped[c]:
		v := hrCents(a.typed[c])
		l.Typed, l.Amount = &v, v
		if isRated {
			l.Diff = hrCents(v - l.Computed)
		}
		if isRated && math.Abs(l.Diff) > hrDiffTolerance {
			l.Flag = "diff"
		}
	case a.hasB[c]:
		v := hrCents(a.booked[c])
		l.Booked, l.Amount = &v, v
		if isRated {
			l.Diff = hrCents(v - l.Computed)
		}
		if math.Abs(l.Diff) > hrDiffTolerance || !isRated {
			l.Flag = "stale"
		}
	case l.Computed > 0:
		return l, true
	}
	return l, false
}

// HRBookings is what booking p writes: every rated line of every person that
// has neither a typed value nor a booked one equal to the calculation, with
// a computed amount above 0. The book action first removes the month's
// booked lines whose component it rebooks.
func HRBookings(p HRPayroll) []HRBooking {
	out := []HRBooking{}
	for _, row := range p.People {
		for _, l := range row.Employer {
			if l.Typed != nil || l.RatePct == nil || l.Computed <= 0 {
				continue
			}
			if l.Booked != nil && l.Flag == "" {
				continue
			}
			out = append(out, HRBooking{PersonID: row.PersonID, Component: l.Component, Currency: row.Currency, Amount: l.Computed})
		}
	}
	return out
}

// HRStaleBooked is the ids of month's booked lines the book action replaces:
// a booked line whose (person, component, currency) is in bs, or whose
// component no rate computes for that person any more (stale with no rate).
func HRStaleBooked(month string, lines []CostEntry, p HRPayroll, bs []HRBooking) []string {
	type key struct{ person, comp, cur string }
	re := map[key]bool{}
	for _, b := range bs {
		re[key{b.PersonID, b.Component, b.Currency}] = true
	}
	for _, row := range p.People {
		for _, l := range row.Employer {
			if l.Booked != nil && l.RatePct == nil {
				re[key{row.PersonID, l.Component, row.Currency}] = true
			}
		}
	}
	out := []string{}
	for _, e := range lines {
		if e.Type == "hr" && e.Period == month && e.PeriodKind != "year" && strings.HasPrefix(e.Source, HRComputedSource) &&
			re[key{e.PersonID, e.Component, e.Currency}] {
			out = append(out, e.ID)
		}
	}
	return out
}

// The Memory driver's rates beside the store.
var (
	memHRRatesMu sync.Mutex
	memHRRates   = map[*Memory]map[string]HRRate{}
)

func hrRateKey(year int, component string) string { return fmt.Sprintf("%04d/%s", year, component) }

// ListHRRates is HRRateStore on Memory.
func (s *Memory) ListHRRates(_ context.Context, year int) ([]HRRate, error) {
	memHRRatesMu.Lock()
	defer memHRRatesMu.Unlock()
	out := []HRRate{}
	for _, r := range memHRRates[s] {
		if r.Year == year {
			r.AppliesTo = slices.Clone(r.AppliesTo)
			out = append(out, r)
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Component < out[j].Component })
	return out, nil
}

// SetHRRate is HRRateStore on Memory.
func (s *Memory) SetHRRate(_ context.Context, r HRRate) (HRRate, error) {
	if why := CheckHRRate(r, DefaultHRComponents); why != "" {
		return HRRate{}, fmt.Errorf("hr rate: %s", why)
	}
	memHRRatesMu.Lock()
	defer memHRRatesMu.Unlock()
	if memHRRates[s] == nil {
		memHRRates[s] = map[string]HRRate{}
	}
	r.AppliesTo = slices.Clone(r.AppliesTo)
	r.SetAt = time.Now().UTC().Truncate(time.Microsecond)
	memHRRates[s][hrRateKey(r.Year, r.Component)] = r
	return r, nil
}

// DeleteHRRate is HRRateStore on Memory.
func (s *Memory) DeleteHRRate(_ context.Context, year int, component string) error {
	memHRRatesMu.Lock()
	defer memHRRatesMu.Unlock()
	k := hrRateKey(year, component)
	if _, ok := memHRRates[s][k]; !ok {
		return ErrNotFound
	}
	delete(memHRRates[s], k)
	return nil
}

var _ HRRateStore = (*Memory)(nil)

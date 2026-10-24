// SPDX-License-Identifier: AGPL-3.0-only

package hours

// Payroll is the line engine of spec 107 v2 FR-39 and FR-40 (task T025): a
// workspace's approved entries of one calendar month become the payroll
// file's lines, and a column map sets the file's layout. It is pure like
// Suggest: no store, no clock, nothing stored. The payroll route
// (GET /v1/hours/payroll, T048) reads the entries, the members' worker types
// (FR-31), the adjustment rows (FR-40, T032) and the column map
// (hours.payroll_columns, T026), calls PayrollLines and RenderPayroll, and
// writes the sheet as CSV or XLSX through 6.2's writer.
//
// The rules:
//
//  1. Only approved entries count (6.2: rejected rows, proposed and disputed
//     rows and open suggestions never appear). Which period states a file
//     holds (Final only by default, 6.2) is the route's filter.
//  2. A month file over weekly freezes: an entry is in the file when its day
//     is in the month, so a weekly period across the month boundary is split
//     at it.
//  3. One line per (member, day, kind, category) with its minutes, summed
//     over targets. The categories are the entry's FR-28 split
//     (category_minutes); minutes the split does not cover count as normal.
//     An absence row has no category: its line carries the FR-30 type.
//  4. The overtime and extra flags (FR-28, computed by T024) are minutes of
//     a category: a line carries the minutes of it flagged overtime and
//     extra, and 0 is no flag.
//  5. The FR-31 worker type and company ride on every line; a
//     subcontractor's lines are left out (their hours roll up per company
//     for invoice checking elsewhere), adjustments included.
//  6. An FR-40 adjustment row is its own line, never summed: signed minutes,
//     the day it corrects, its required reason, booked on the day the route
//     gives it (BookDay, in the open period it landed in). A paid period is
//     never rewritten.
//  7. No money (FR-19): no column carries a rate, an amount or a cost.

import (
	"errors"
	"fmt"
	"maps"
	"slices"
	"strconv"
	"strings"
	"time"
)

// PayrollMember is a member's FR-31 contract facts, from the membership
// settings. WorkerType "" is an employee.
type PayrollMember struct {
	Name       string
	WorkerType string // "", "employee", "agency", "subcontractor"
	Company    string // the agency's or the subcontractor's name
}

// PayrollEntry is one hours_entries row (rdb 0215) as the export reads it.
type PayrollEntry struct {
	Member      string
	Day         string // YYYY-MM-DD, the workspace's date
	Target      string
	Kind        string // work, travel, wait, absence
	AbsenceType string // set exactly on an absence row
	State       string // only EntryApproved counts
	Minutes     int
	// CategoryMinutes is the FR-28 split; it sums to at most Minutes.
	CategoryMinutes map[string]int
	// OvertimeMinutes and ExtraMinutes are the minutes of a category flagged
	// overtime or extra (T024); together at most that category's minutes.
	OvertimeMinutes map[string]int
	ExtraMinutes    map[string]int
}

// PayrollAdjustment is one hours_adjustments row (FR-40, T022).
type PayrollAdjustment struct {
	Member      string
	BookDay     string // the day it counts on, in the period it landed in
	CorrectsDay string // the day of the approved row it corrects
	Kind        string
	Target      string
	Minutes     int // signed, never 0
	Reason      string
}

// PayrollInput is one workspace's month.
type PayrollInput struct {
	Month       string // YYYY-MM
	Members     map[string]PayrollMember
	Entries     []PayrollEntry
	Adjustments []PayrollAdjustment
}

// PayrollLine is one line of the file.
type PayrollLine struct {
	Day             string
	Member          string
	MemberName      string
	WorkerType      string
	Company         string
	Kind            string
	AbsenceType     string
	Category        string // "" on an absence and an adjustment line
	Minutes         int
	OvertimeMinutes int
	ExtraMinutes    int
	Adjustment      bool
	CorrectsDay     string
	Reason          string
}

// PayrollColumn is one entry of the column map: a known column and the
// header it is written under ("" keeps the column's name). The map's order
// is the file's; a column not in it is dropped.
type PayrollColumn struct {
	Column string `json:"column"`
	Header string `json:"header,omitempty"`
}

// PayrollSheet is the rendered file: a header, one row per line, and which
// columns are numbers (XLSX numeric cells, 6.2).
type PayrollSheet struct {
	Header  []string
	Numeric []bool
	Rows    [][]string
}

const (
	payrollEmployee      = "employee"
	payrollAgency        = "agency"
	payrollSubcontractor = "subcontractor"
	payrollAbsence       = "absence"
	payrollNormal        = "normal"
)

// The store's strings (rdb 0215 CHECKs); each list is in the file's order.
var (
	payrollKinds        = []string{"work", "travel", "wait", payrollAbsence}
	payrollCategories   = []string{payrollNormal, "evening", "night", "weekend", "holiday"}
	payrollAbsenceTypes = []string{"sick", "vacation", "unpaid", "training", "holiday"}
	payrollWorkerTypes  = []string{payrollEmployee, payrollAgency, payrollSubcontractor}
)

type payrollField struct {
	name    string
	numeric bool
	value   func(PayrollLine) string
}

func itoa(n int) string { return strconv.Itoa(n) }

func yes(b bool) string {
	if b {
		return "yes"
	}
	return ""
}

// payrollFields are the known columns, in the default order.
var payrollFields = []payrollField{
	{"date", false, func(l PayrollLine) string { return l.Day }},
	{"member_id", false, func(l PayrollLine) string { return l.Member }},
	{"member_name", false, func(l PayrollLine) string { return l.MemberName }},
	{"worker_type", false, func(l PayrollLine) string { return l.WorkerType }},
	{"company", false, func(l PayrollLine) string { return l.Company }},
	{"kind", false, func(l PayrollLine) string { return l.Kind }},
	{"absence_type", false, func(l PayrollLine) string { return l.AbsenceType }},
	{"category", false, func(l PayrollLine) string { return l.Category }},
	{"minutes", true, func(l PayrollLine) string { return itoa(l.Minutes) }},
	{"hours_decimal", true, func(l PayrollLine) string { return strconv.FormatFloat(float64(l.Minutes)/60, 'f', 2, 64) }},
	{"overtime_minutes", true, func(l PayrollLine) string { return itoa(l.OvertimeMinutes) }},
	{"extra_minutes", true, func(l PayrollLine) string { return itoa(l.ExtraMinutes) }},
	{"adjustment", false, func(l PayrollLine) string { return yes(l.Adjustment) }},
	{"corrects_day", false, func(l PayrollLine) string { return l.CorrectsDay }},
	{"reason", false, func(l PayrollLine) string { return l.Reason }},
}

// DefaultPayrollColumns is the column map of a workspace that set none:
// every known column, in order, under its own name. T026 registers it as the
// default of hours.payroll_columns.
func DefaultPayrollColumns() []PayrollColumn {
	cols := make([]PayrollColumn, len(payrollFields))
	for i, f := range payrollFields {
		cols[i] = PayrollColumn{Column: f.name}
	}
	return cols
}

// ValidPayrollColumns refuses an unknown, an empty or a repeated column
// (T026 calls it on a write of hours.payroll_columns).
func ValidPayrollColumns(cols []PayrollColumn) error {
	_, err := payrollLayout(cols)
	return err
}

func payrollLayout(cols []PayrollColumn) ([]payrollField, error) {
	if cols == nil {
		cols = DefaultPayrollColumns()
	}
	byName := map[string]payrollField{}
	for _, f := range payrollFields {
		byName[f.name] = f
	}
	seen := map[string]bool{}
	out := make([]payrollField, 0, len(cols))
	for _, c := range cols {
		f, ok := byName[c.Column]
		switch {
		case !ok:
			return nil, fmt.Errorf("hours: payroll column %q unknown", c.Column)
		case seen[c.Column]:
			return nil, fmt.Errorf("hours: payroll column %q twice", c.Column)
		}
		seen[c.Column] = true
		if c.Header != "" {
			f.name = c.Header
		}
		out = append(out, f)
	}
	return out, nil
}

// RenderPayroll lays the lines out by the column map; nil is the default.
func RenderPayroll(lines []PayrollLine, cols []PayrollColumn) (PayrollSheet, error) {
	fields, err := payrollLayout(cols)
	if err != nil {
		return PayrollSheet{}, err
	}
	s := PayrollSheet{Header: make([]string, len(fields)), Numeric: make([]bool, len(fields)),
		Rows: make([][]string, 0, len(lines))}
	for i, f := range fields {
		s.Header[i], s.Numeric[i] = f.name, f.numeric
	}
	for _, l := range lines {
		row := make([]string, len(fields))
		for i, f := range fields {
			row[i] = f.value(l)
		}
		s.Rows = append(s.Rows, row)
	}
	return s, nil
}

// payrollMonth is the month's first and last day as YYYY-MM-DD.
func payrollMonth(month string) (first, last string, err error) {
	t, err := time.Parse("2006-01", month)
	if err != nil {
		return "", "", fmt.Errorf("hours: payroll month %q: want YYYY-MM", month)
	}
	return t.Format(time.DateOnly), t.AddDate(0, 1, -1).Format(time.DateOnly), nil
}

func payrollDay(what, day string) error {
	if _, err := time.Parse(time.DateOnly, day); err != nil {
		return fmt.Errorf("hours: payroll %s %q: want YYYY-MM-DD", what, day)
	}
	return nil
}

// payrollWorkers checks the members' worker types; "" is an employee.
func payrollWorkers(in map[string]PayrollMember) (map[string]PayrollMember, error) {
	out := make(map[string]PayrollMember, len(in))
	for id, m := range in {
		if m.WorkerType == "" {
			m.WorkerType = payrollEmployee
		}
		if !slices.Contains(payrollWorkerTypes, m.WorkerType) {
			return nil, fmt.Errorf("hours: member %s: worker type %q unknown", id, m.WorkerType)
		}
		out[id] = m
	}
	return out, nil
}

func (m PayrollMember) line(member, day, kind string) PayrollLine {
	if m.WorkerType == "" {
		m.WorkerType = payrollEmployee
	}
	return PayrollLine{Day: day, Member: member, MemberName: m.Name, WorkerType: m.WorkerType,
		Company: m.Company, Kind: kind}
}

type payrollKey struct{ member, day, kind, absence, category string }

// PayrollLines turns one month's approved entries and adjustments into the
// file's lines, sorted by day, member, then regular lines (kind, category in
// the store's order) before adjustments. Input the store could never hold is
// an error.
func PayrollLines(in PayrollInput) ([]PayrollLine, error) {
	first, last, err := payrollMonth(in.Month)
	if err != nil {
		return nil, err
	}
	members, err := payrollWorkers(in.Members)
	if err != nil {
		return nil, err
	}
	inMonth := func(day string) bool { return day >= first && day <= last }
	sums := map[payrollKey]*PayrollLine{}
	seen := map[[4]string]bool{}
	for _, e := range in.Entries {
		if err := checkPayrollEntry(e); err != nil {
			return nil, err
		}
		key := [4]string{e.Member, e.Day, e.Target, e.Kind}
		if seen[key] {
			return nil, fmt.Errorf("hours: entry %s %s %s %s twice", e.Member, e.Day, e.Target, e.Kind)
		}
		seen[key] = true
		m := members[e.Member]
		if e.State != EntryApproved || !inMonth(e.Day) || m.WorkerType == payrollSubcontractor {
			continue
		}
		addPayrollEntry(sums, m, e)
	}
	lines := make([]PayrollLine, 0, len(sums)+len(in.Adjustments))
	for _, l := range sums {
		lines = append(lines, *l)
	}
	for _, a := range in.Adjustments {
		if err := checkPayrollAdjustment(a); err != nil {
			return nil, err
		}
		m := members[a.Member]
		if !inMonth(a.BookDay) || m.WorkerType == payrollSubcontractor {
			continue
		}
		l := m.line(a.Member, a.BookDay, a.Kind)
		l.Minutes, l.Adjustment, l.CorrectsDay, l.Reason = a.Minutes, true, a.CorrectsDay, a.Reason
		lines = append(lines, l)
	}
	slices.SortStableFunc(lines, comparePayrollLines)
	return lines, nil
}

// addPayrollEntry adds an approved entry's minutes to its lines.
func addPayrollEntry(sums map[payrollKey]*PayrollLine, m PayrollMember, e PayrollEntry) {
	add := func(category string, minutes, overtime, extra int) {
		if minutes == 0 {
			return
		}
		k := payrollKey{e.Member, e.Day, e.Kind, e.AbsenceType, category}
		l, ok := sums[k]
		if !ok {
			nl := m.line(e.Member, e.Day, e.Kind)
			nl.AbsenceType, nl.Category = e.AbsenceType, category
			l = &nl
			sums[k] = l
		}
		l.Minutes += minutes
		l.OvertimeMinutes += overtime
		l.ExtraMinutes += extra
	}
	if e.Kind == payrollAbsence {
		add("", e.Minutes, 0, 0)
		return
	}
	rest := e.Minutes
	for _, c := range slices.Sorted(maps.Keys(e.CategoryMinutes)) {
		rest -= e.CategoryMinutes[c]
		add(c, e.CategoryMinutes[c], e.OvertimeMinutes[c], e.ExtraMinutes[c])
	}
	add(payrollNormal, rest, 0, 0)
}

func checkPayrollEntry(e PayrollEntry) error {
	where := fmt.Sprintf("hours: entry %s %s %s %s", e.Member, e.Day, e.Target, e.Kind)
	if e.Member == "" {
		return errors.New(where + ": no member")
	}
	if err := payrollDay("day", e.Day); err != nil {
		return err
	}
	if !slices.Contains(payrollKinds, e.Kind) {
		return fmt.Errorf("%s: kind unknown", where)
	}
	if (e.Kind == payrollAbsence) != (e.AbsenceType != "") || (e.AbsenceType != "" && !slices.Contains(payrollAbsenceTypes, e.AbsenceType)) {
		return fmt.Errorf("%s: absence type %q", where, e.AbsenceType)
	}
	if e.Minutes < 0 {
		return fmt.Errorf("%s: minutes %d < 0", where, e.Minutes)
	}
	if e.Kind == payrollAbsence && len(e.CategoryMinutes)+len(e.OvertimeMinutes)+len(e.ExtraMinutes) > 0 {
		return fmt.Errorf("%s: an absence has no categories", where)
	}
	return checkPayrollSplit(where, e)
}

// checkPayrollSplit checks the FR-28 split and its flags.
func checkPayrollSplit(where string, e PayrollEntry) error {
	sum := 0
	for c, n := range e.CategoryMinutes {
		if !slices.Contains(payrollCategories, c) || n < 0 {
			return fmt.Errorf("%s: category %q %d", where, c, n)
		}
		sum += n
	}
	if sum > e.Minutes {
		return fmt.Errorf("%s: categories %d > minutes %d", where, sum, e.Minutes)
	}
	for _, c := range slices.Concat(slices.Collect(maps.Keys(e.OvertimeMinutes)), slices.Collect(maps.Keys(e.ExtraMinutes))) {
		ot, ex := e.OvertimeMinutes[c], e.ExtraMinutes[c]
		if ot < 0 || ex < 0 || ot+ex > e.CategoryMinutes[c] {
			return fmt.Errorf("%s: %s overtime %d + extra %d > %d", where, c, ot, ex, e.CategoryMinutes[c])
		}
	}
	return nil
}

func checkPayrollAdjustment(a PayrollAdjustment) error {
	where := fmt.Sprintf("hours: adjustment %s %s of %s", a.Member, a.BookDay, a.CorrectsDay)
	if a.Member == "" {
		return errors.New(where + ": no member")
	}
	if err := payrollDay("adjustment day", a.BookDay); err != nil {
		return err
	}
	if err := payrollDay("corrected day", a.CorrectsDay); err != nil {
		return err
	}
	switch {
	case a.CorrectsDay > a.BookDay:
		return errors.New(where + ": corrects a later day")
	case !slices.Contains(payrollKinds, a.Kind):
		return fmt.Errorf("%s: kind %q unknown", where, a.Kind)
	case a.Minutes == 0:
		return errors.New(where + ": 0 minutes")
	case strings.TrimSpace(a.Reason) == "":
		return errors.New(where + ": a reason is required (FR-40)")
	}
	return nil
}

func comparePayrollLines(a, b PayrollLine) int {
	rank := func(list []string, s string) int { return slices.Index(list, s) }
	adj := func(l PayrollLine) int {
		if l.Adjustment {
			return 1
		}
		return 0
	}
	for _, c := range []int{
		strings.Compare(a.Day, b.Day),
		strings.Compare(a.Member, b.Member),
		adj(a) - adj(b),
		rank(payrollKinds, a.Kind) - rank(payrollKinds, b.Kind),
		rank(payrollCategories, a.Category) - rank(payrollCategories, b.Category),
		strings.Compare(a.CorrectsDay, b.CorrectsDay),
	} {
		if c != 0 {
			return c
		}
	}
	return 0
}

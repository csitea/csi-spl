// SPDX-License-Identifier: AGPL-3.0-only

package hours

import (
	"bytes"
	"encoding/csv"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"testing"
)

// payrollCSV renders a sheet as the CSV the golden files hold.
func payrollCSV(t *testing.T, s PayrollSheet) string {
	t.Helper()
	var b bytes.Buffer
	w := csv.NewWriter(&b)
	if err := w.Write(s.Header); err != nil {
		t.Fatal(err)
	}
	if err := w.WriteAll(s.Rows); err != nil {
		t.Fatal(err)
	}
	return b.String()
}

func checkGolden(t *testing.T, name, got string) {
	t.Helper()
	want, err := os.ReadFile(filepath.Join("testdata", name))
	if err != nil {
		t.Fatalf("golden %s: %v", name, err)
	}
	if got != string(want) {
		t.Errorf("%s differs\n--- got\n%s--- want\n%s", name, got, want)
	}
}

func payrollRender(t *testing.T, in PayrollInput, cols []PayrollColumn) PayrollSheet {
	t.Helper()
	lines, err := PayrollLines(in)
	if err != nil {
		t.Fatalf("PayrollLines: %v", err)
	}
	s, err := RenderPayroll(lines, cols)
	if err != nil {
		t.Fatalf("RenderPayroll: %v", err)
	}
	return s
}

// payrollMembers: an employee, an agency worker, a subcontractor. Kinds,
// categories, absence and worker types are the store's strings (rdb 0215,
// FR-31), written out: T023 and T024 own their constants in this package.
func payrollMembers() map[string]PayrollMember {
	return map[string]PayrollMember{
		"m1": {Name: "Worker One"},
		"m2": {Name: "Worker Two", WorkerType: "agency", Company: "Agency Oy"},
		"m3": {Name: "Worker Three", WorkerType: "subcontractor", Company: "Sub Ltd"},
	}
}

func approved(member, day, target, kind string, minutes int, cat map[string]int) PayrollEntry {
	return PayrollEntry{Member: member, Day: day, Target: target, Kind: kind, State: EntryApproved,
		Minutes: minutes, CategoryMinutes: cat}
}

// The week Mon 2026-09-28 .. Sun 2026-10-04 crosses the month boundary: the
// October file holds Thu 1..Sun 4 only, September's holds Mon 28..Wed 30.
func weekAcrossMonth() PayrollInput {
	var es []PayrollEntry
	for _, d := range []string{"2026-09-28", "2026-09-29", "2026-09-30", "2026-10-01", "2026-10-02"} {
		es = append(es, approved("m1", d, "job:a", "work", 480, map[string]int{"normal": 480}))
	}
	// two targets on one day roll up into one line per (member, day, kind,
	// category); a row with no split counts as normal
	es = append(es,
		approved("m1", "2026-10-02", "job:b", "work", 90, map[string]int{"evening": 60}),
		approved("m1", "2026-10-02", "job:b", "travel", 30, nil),
	)
	// Saturday: weekend minutes past the weekly threshold (overtime) and above
	// the person's own standard (extra); Sunday the FR-30 absence with its type
	sat := approved("m1", "2026-10-03", "job:a", "work", 240, map[string]int{"weekend": 240})
	sat.OvertimeMinutes = map[string]int{"weekend": 180}
	sat.ExtraMinutes = map[string]int{"weekend": 60}
	es = append(es, sat, PayrollEntry{Member: "m2", Day: "2026-10-04", Target: "ws", Kind: "absence",
		AbsenceType: "sick", State: EntryApproved, Minutes: 480})
	// not approved: never in the file
	es = append(es,
		PayrollEntry{Member: "m1", Day: "2026-10-01", Target: "job:c", Kind: "work", State: EntryRejected, Minutes: 99},
		PayrollEntry{Member: "m1", Day: "2026-10-01", Target: "job:d", Kind: "work", State: "proposed", Minutes: 98},
	)
	return PayrollInput{Members: payrollMembers(), Entries: es}
}

func TestPayrollWeekAcrossMonthBoundary(t *testing.T) {
	in := weekAcrossMonth()
	in.Month = "2026-10"
	checkGolden(t, "payroll_month_split_oct.csv", payrollCSV(t, payrollRender(t, in, nil)))
	in.Month = "2026-09"
	checkGolden(t, "payroll_month_split_sep.csv", payrollCSV(t, payrollRender(t, in, nil)))
}

func TestPayrollColumnMapRenameOrderDrop(t *testing.T) {
	in := weekAcrossMonth()
	in.Month = "2026-10"
	cols := []PayrollColumn{
		{Column: "member_name", Header: "Employee"},
		{Column: "date", Header: "Day"},
		{Column: "category"},
		{Column: "minutes", Header: "Min"},
		{Column: "overtime_minutes", Header: "OT"},
	}
	s := payrollRender(t, in, cols)
	checkGolden(t, "payroll_columns_dropped.csv", payrollCSV(t, s))
	if want := []bool{false, false, false, true, true}; !slices.Equal(s.Numeric, want) {
		t.Errorf("Numeric %v, want %v", s.Numeric, want)
	}
	for _, h := range s.Header {
		if h == "member_id" || h == "worker_type" {
			t.Errorf("dropped column %q still in the header %v", h, s.Header)
		}
	}
}

func TestPayrollSubcontractorLeftOut(t *testing.T) {
	in := PayrollInput{Month: "2026-10", Members: payrollMembers(), Entries: []PayrollEntry{
		approved("m1", "2026-10-05", "job:a", "work", 450, map[string]int{"normal": 450}),
		approved("m2", "2026-10-05", "job:a", "work", 420, map[string]int{"normal": 420}),
		approved("m3", "2026-10-05", "job:a", "work", 600, map[string]int{"normal": 600}),
	}, Adjustments: []PayrollAdjustment{
		{Member: "m3", BookDay: "2026-10-06", CorrectsDay: "2026-09-21", Kind: "work", Minutes: 30, Reason: "late"},
	}}
	got := payrollCSV(t, payrollRender(t, in, nil))
	checkGolden(t, "payroll_subcontractor_out.csv", got)
	if strings.Contains(got, "m3") || strings.Contains(got, "Sub Ltd") {
		t.Errorf("a subcontractor line is in the file:\n%s", got)
	}
}

func TestPayrollAdjustmentLines(t *testing.T) {
	in := PayrollInput{Month: "2026-10", Members: payrollMembers(), Entries: []PayrollEntry{
		approved("m1", "2026-10-12", "job:a", "work", 480, map[string]int{"normal": 480}),
	}, Adjustments: []PayrollAdjustment{
		{Member: "m1", BookDay: "2026-10-12", CorrectsDay: "2026-09-30", Kind: "work", Target: "job:a", Minutes: -45, Reason: "double entry"},
		{Member: "m1", BookDay: "2026-10-12", CorrectsDay: "2026-09-29", Kind: "travel", Target: "job:a", Minutes: 30, Reason: "travel missed"},
		// booked in November: not in October's file
		{Member: "m1", BookDay: "2026-11-02", CorrectsDay: "2026-10-12", Kind: "work", Minutes: 15, Reason: "x"},
	}}
	checkGolden(t, "payroll_adjustments.csv", payrollCSV(t, payrollRender(t, in, nil)))
}

func TestPayrollRefusesBadInput(t *testing.T) {
	ok := func() PayrollInput {
		return PayrollInput{Month: "2026-10", Entries: []PayrollEntry{
			approved("m1", "2026-10-05", "job:a", "work", 60, map[string]int{"normal": 60}),
		}}
	}
	adj := func(a PayrollAdjustment) func(*PayrollInput) {
		return func(in *PayrollInput) { in.Adjustments = []PayrollAdjustment{a} }
	}
	cases := map[string]func(*PayrollInput){
		"bad month":          func(in *PayrollInput) { in.Month = "2026-13" },
		"bad day":            func(in *PayrollInput) { in.Entries[0].Day = "2026-10-32" },
		"bad kind":           func(in *PayrollInput) { in.Entries[0].Kind = "nap" },
		"unknown category":   func(in *PayrollInput) { in.Entries[0].CategoryMinutes = map[string]int{"premium": 60} },
		"categories > total": func(in *PayrollInput) { in.Entries[0].CategoryMinutes = map[string]int{"normal": 61} },
		"negative category":  func(in *PayrollInput) { in.Entries[0].CategoryMinutes = map[string]int{"normal": -1} },
		"negative minutes":   func(in *PayrollInput) { in.Entries[0].Minutes = -1 },
		"overtime > category": func(in *PayrollInput) {
			in.Entries[0].OvertimeMinutes = map[string]int{"normal": 61}
		},
		"overtime + extra > category": func(in *PayrollInput) {
			in.Entries[0].OvertimeMinutes = map[string]int{"normal": 40}
			in.Entries[0].ExtraMinutes = map[string]int{"normal": 21}
		},
		"absence without type": func(in *PayrollInput) {
			in.Entries[0].Kind, in.Entries[0].CategoryMinutes = "absence", nil
		},
		"absence with categories": func(in *PayrollInput) {
			in.Entries[0].Kind, in.Entries[0].AbsenceType = "absence", "vacation"
		},
		"type on work row":    func(in *PayrollInput) { in.Entries[0].AbsenceType = "sick" },
		"bad worker type":     func(in *PayrollInput) { in.Members = map[string]PayrollMember{"m1": {WorkerType: "intern"}} },
		"no member":           func(in *PayrollInput) { in.Entries[0].Member = "" },
		"twice":               func(in *PayrollInput) { in.Entries = append(in.Entries, in.Entries[0]) },
		"adjustment reason":   adj(PayrollAdjustment{Member: "m1", BookDay: "2026-10-05", CorrectsDay: "2026-09-01", Kind: "work", Minutes: 5}),
		"adjustment zero":     adj(PayrollAdjustment{Member: "m1", BookDay: "2026-10-05", CorrectsDay: "2026-09-01", Kind: "work", Reason: "r"}),
		"adjustment kind":     adj(PayrollAdjustment{Member: "m1", BookDay: "2026-10-05", CorrectsDay: "2026-09-01", Kind: "nap", Minutes: 5, Reason: "r"}),
		"adjustment no day":   adj(PayrollAdjustment{Member: "m1", CorrectsDay: "2026-09-01", Kind: "work", Minutes: 5, Reason: "r"}),
		"adjustment member":   adj(PayrollAdjustment{BookDay: "2026-10-05", CorrectsDay: "2026-09-01", Kind: "work", Minutes: 5, Reason: "r"}),
		"adjustment blank":    adj(PayrollAdjustment{Member: "m1", BookDay: "2026-10-05", CorrectsDay: "2026-09-01", Kind: "work", Minutes: 5, Reason: "  "}),
		"adjustment of later": adj(PayrollAdjustment{Member: "m1", BookDay: "2026-10-05", CorrectsDay: "2026-10-06", Kind: "work", Minutes: 5, Reason: "r"}),
	}
	if _, err := PayrollLines(ok()); err != nil {
		t.Fatalf("the base input is refused: %v", err)
	}
	for name, mut := range cases {
		in := ok()
		mut(&in)
		if _, err := PayrollLines(in); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestPayrollColumnMapRefused(t *testing.T) {
	cases := map[string][]PayrollColumn{
		"unknown column": {{Column: "rate"}},
		"twice":          {{Column: "date"}, {Column: "date", Header: "Day"}},
		"empty column":   {{Header: "x"}},
	}
	for name, cols := range cases {
		if err := ValidPayrollColumns(cols); err == nil {
			t.Errorf("%s: ValidPayrollColumns accepted %v", name, cols)
		}
		if _, err := RenderPayroll(nil, cols); err == nil {
			t.Errorf("%s: RenderPayroll accepted %v", name, cols)
		}
	}
	if err := ValidPayrollColumns(DefaultPayrollColumns()); err != nil {
		t.Errorf("the default map is refused: %v", err)
	}
	// the default is a copy: a caller's edit never changes the next default
	d := DefaultPayrollColumns()
	d[0].Column = "x"
	if DefaultPayrollColumns()[0].Column == "x" {
		t.Error("DefaultPayrollColumns hands out its own slice")
	}
}

// FR-19: no money in hours tracking, so no column may carry a rate, an
// amount or a cost.
func TestPayrollColumnsCarryNoMoney(t *testing.T) {
	for _, c := range DefaultPayrollColumns() {
		for _, bad := range []string{"rate", "amount", "cost", "pay", "eur", "price", "wage", "salary"} {
			if strings.Contains(c.Column, bad) {
				t.Errorf("column %q carries money (%q)", c.Column, bad)
			}
		}
	}
}

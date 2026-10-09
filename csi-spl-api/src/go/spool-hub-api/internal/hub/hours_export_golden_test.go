package hub

import (
	"bytes"
	"flag"
	"os"
	"strconv"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/xlsx"
)

var updateHoursExport = flag.Bool("update-hours-export", false, "rewrite testdata/hours_export.golden.csv")

// hoursExportFixture is a week of two members: a final, b frozen; one line
// per target type, a note a spreadsheet would read as a formula.
func hoursExportFixture() (*hoursTeamData, hoursNames, store.HoursSettings, time.Time) {
	set := store.HoursSettings{Period: store.HoursPeriodWeek, GraceDays: 2, IdleMinutes: 10, TZ: "UTC"}
	now := time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)
	day, _ := time.Parse(hoursDayLayout, "2026-09-30")
	q := hoursTeamQuery{day: day}
	q.start, q.end = store.HoursPeriodBounds(set.Period, day)
	decided := time.Date(2026, 10, 7, 9, 30, 0, 0, time.UTC)
	approvedAt := time.Date(2026, 10, 1, 17, 0, 0, 0, time.UTC)
	ent := func(member, d, target string, minutes, suggested int, note string) store.HoursTeamEntry {
		return store.HoursTeamEntry{Member: member, HoursEntry: store.HoursEntry{Day: d, Target: target, Minutes: minutes,
			SuggestedMinutes: suggested, State: store.HoursApproved, Note: note, UpdatedAt: approvedAt, UpdatedBy: member}}
	}
	d := &hoursTeamData{q: q, names: map[string]string{"HUM-a": "FirstName LastName", "HUM-b": "Second Member"},
		members: []string{"HUM-a", "HUM-b"},
		rows: map[string]store.HoursPeriod{
			"HUM-a": {Member: "HUM-a", Start: "2026-09-28", End: "2026-10-04", State: store.HoursApproved, Minutes: 335,
				DecidedBy: "HUM-owner", DecidedAt: decided},
			"HUM-b": {Member: "HUM-b", Start: "2026-09-28", End: "2026-10-04", State: store.HoursFrozen, Minutes: 45,
				DecidedBy: store.HoursSweepBy, DecidedAt: decided},
		},
		entries: []store.HoursTeamEntry{
			ent("HUM-a", "2026-09-29", "cal:ev-1", 60, 60, ""),
			ent("HUM-a", "2026-09-29", "ch:general", 25, 20, "=SUM(A1:A9)"),
			ent("HUM-a", "2026-09-29", "t:task-issue", 90, 75, "edited, \"quoted\""),
			ent("HUM-a", "2026-09-30", "dm:HUM-b", 10, 10, ""),
			ent("HUM-a", "2026-09-30", "t:task-topic", 120, 120, ""),
			ent("HUM-a", "2026-09-30", "ws", 30, 0, "call with a customer"),
			ent("HUM-b", "2026-09-29", "t:task-topic", 45, 45, ""),
		},
	}
	n := hoursNames{members: d.names,
		issues:   map[string]store.Issue{"task-issue": {Prefix: "SPL", Number: 12, Title: "Export the hours", TaskID: "task-issue"}},
		meetings: map[string]string{"ev-1": "Weekly sync"}}
	return d, n, set, now
}

// The CSV golden file: the spec's columns, one line per approved entry of a
// final period by default.
func TestHoursExportCSVGolden(t *testing.T) {
	d, n, set, now := hoursExportFixture()
	got, err := hoursCSV(hoursExportLines(d, n, set, now, true, "member"))
	if err != nil {
		t.Fatal(err)
	}
	const path = "testdata/hours_export.golden.csv"
	if *updateHoursExport {
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatal(err)
		}
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("CSV differs from %s (-update-hours-export rewrites it):\n%s", path, got)
	}
}

// final=false adds the frozen member; group=day orders by day first.
func TestHoursExportNotFinalGroupDay(t *testing.T) {
	d, n, set, now := hoursExportFixture()
	lines := hoursExportLines(d, n, set, now, false, "day")
	if len(lines) != 7 {
		t.Fatalf("%d lines, want 7", len(lines))
	}
	if lines[0].Date != "2026-09-29" || lines[len(lines)-1].Date != "2026-09-30" || lines[3].Member != "HUM-b" {
		t.Fatalf("order: %+v", lines)
	}
	if b := lines[3]; b.PeriodState != store.HoursFrozen || b.By != "HUM-b" {
		t.Fatalf("frozen line: %+v", b)
	}
}

// The XLSX holds the CSV's cells, minutes and hours as numbers.
func TestHoursExportXLSXCells(t *testing.T) {
	d, n, set, now := hoursExportFixture()
	lines := hoursExportLines(d, n, set, now, true, "member")
	raw, err := hoursXLSX(lines)
	if err != nil {
		t.Fatal(err)
	}
	cells, err := xlsx.Read(bytes.NewReader(raw), int64(len(raw)))
	if err != nil {
		t.Fatal(err)
	}
	types, _ := xlsx.CellTypes(bytes.NewReader(raw), int64(len(raw)))
	if len(cells) != len(lines)+1 || cells[0][8] != "hours_decimal" {
		t.Fatalf("rows: %v", cells)
	}
	for i, l := range lines {
		row := cells[i+1]
		if row[0] != l.Date || row[1] != l.Member || row[7] != strconv.Itoa(l.Minutes) || types[i+1][7] != "n" || types[i+1][8] != "n" {
			t.Fatalf("row %d: %v types %v", i+1, row, types[i+1])
		}
	}
	if cells[2][8] != "1.5" || cells[2][6] != "SPL-12" {
		t.Fatalf("issue row: %v", cells[2])
	}
}

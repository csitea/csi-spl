// SPDX-License-Identifier: AGPL-3.0-only

package hours

import (
	"encoding/json"
	"os"
	"path/filepath"
	"reflect"
	"regexp"
	"slices"
	"strings"
	"testing"
	"time"
)

func helsinki(t *testing.T) *time.Location {
	t.Helper()
	z, err := time.LoadLocation("Europe/Helsinki")
	if err != nil {
		t.Fatalf("zone: %v", err)
	}
	return z
}

func utc(s string) time.Time {
	at, err := time.Parse(time.RFC3339, s)
	if err != nil {
		panic(err)
	}
	return at
}

func sp(from, to string) TimeSpan { return TimeSpan{Start: utc(from), End: utc(to)} }

func ent(state string, minutes int, spans ...TimeSpan) AcrossEntry {
	return AcrossEntry{Target: "t:1", Minutes: minutes, State: state, Spans: spans}
}

func wday(ws, day string, entries ...AcrossEntry) WorkspaceDay {
	return WorkspaceDay{Workspace: ws, Day: day, Entries: entries}
}

type wantDay struct {
	Totals
	approx    bool
	intervals []OverlapInterval
}

func iv(from, to string, ws ...string) OverlapInterval {
	return OverlapInterval{Start: utc(from), End: utc(to), Workspaces: ws}
}

func checkDays(t *testing.T, got []PersonalDay, want map[string]wantDay) {
	t.Helper()
	days := map[string]PersonalDay{}
	for _, d := range got {
		days[d.Day] = d
	}
	if len(days) != len(want) {
		t.Fatalf("days %v, want %d", dayNames(got), len(want))
	}
	for day, w := range want {
		g, ok := days[day]
		if !ok {
			t.Fatalf("day %s missing in %v", day, dayNames(got))
		}
		if g.Totals != w.Totals {
			t.Errorf("%s totals %+v, want %+v", day, g.Totals, w.Totals)
		}
		if g.Approx != w.approx {
			t.Errorf("%s approx %v, want %v", day, g.Approx, w.approx)
		}
		if w.intervals == nil {
			w.intervals = []OverlapInterval{}
		}
		if !reflect.DeepEqual(g.OverlapIntervals, w.intervals) {
			t.Errorf("%s intervals %+v, want %+v", day, g.OverlapIntervals, w.intervals)
		}
	}
}

func dayNames(days []PersonalDay) []string {
	var out []string
	for _, d := range days {
		out = append(out, d.Day)
	}
	return out
}

// T-R1a: A 09:00..12:00, B 10:00..13:00 -> reported 6:00, actual 4:00,
// overlap 2:00, one interval 10:00..12:00 [A, B].
func TestAcrossTR1a(t *testing.T) {
	got, err := Across([]WorkspaceDay{
		wday("A", "2026-10-13", ent(EntryApproved, 180, sp("2026-10-13T09:00:00Z", "2026-10-13T12:00:00Z"))),
		wday("B", "2026-10-13", ent(EntryApproved, 180, sp("2026-10-13T10:00:00Z", "2026-10-13T13:00:00Z"))),
	}, time.UTC, utc("2026-10-13T18:00:00Z"))
	if err != nil {
		t.Fatal(err)
	}
	checkDays(t, got, map[string]wantDay{"2026-10-13": {
		Totals:    Totals{Reported: 360, Actual: 240, Overlap: 120},
		intervals: []OverlapInterval{iv("2026-10-13T10:00:00Z", "2026-10-13T12:00:00Z", "A", "B")},
	}})
}

// T-OV: the edge table of spec 118 6.2 and 6.3.
func TestAcrossTOV(t *testing.T) {
	hki := helsinki(t)
	unavailable := WorkspaceDay{Workspace: "B", Day: "2026-10-13", Unavailable: true}
	cases := []struct {
		name string
		zone *time.Location
		days []WorkspaceDay
		want map[string]wantDay
	}{
		{
			name: "disjoint: actual = reported",
			zone: time.UTC,
			days: []WorkspaceDay{
				wday("A", "2026-10-13", ent(EntryApproved, 60, sp("2026-10-13T09:00:00Z", "2026-10-13T10:00:00Z"))),
				wday("B", "2026-10-13", ent(EntryApproved, 60, sp("2026-10-13T11:00:00Z", "2026-10-13T12:00:00Z"))),
			},
			want: map[string]wantDay{"2026-10-13": {Totals: Totals{Reported: 120, Actual: 120}}},
		},
		{
			name: "touching [a,b)+[b,c): no overlap",
			zone: time.UTC,
			days: []WorkspaceDay{
				wday("A", "2026-10-13", ent(EntryApproved, 60, sp("2026-10-13T09:00:00Z", "2026-10-13T10:00:00Z"))),
				wday("B", "2026-10-13", ent(EntryApproved, 60, sp("2026-10-13T10:00:00Z", "2026-10-13T11:00:00Z"))),
			},
			want: map[string]wantDay{"2026-10-13": {Totals: Totals{Reported: 120, Actual: 120}}},
		},
		{
			name: "three workspaces in a chain",
			zone: time.UTC,
			days: []WorkspaceDay{
				wday("A", "2026-10-13", ent(EntryApproved, 120, sp("2026-10-13T09:00:00Z", "2026-10-13T11:00:00Z"))),
				wday("B", "2026-10-13", ent(EntryApproved, 120, sp("2026-10-13T10:00:00Z", "2026-10-13T12:00:00Z"))),
				wday("C", "2026-10-13", ent(EntryApproved, 120, sp("2026-10-13T11:00:00Z", "2026-10-13T13:00:00Z"))),
			},
			want: map[string]wantDay{"2026-10-13": {
				Totals: Totals{Reported: 360, Actual: 240, Overlap: 120},
				intervals: []OverlapInterval{
					iv("2026-10-13T10:00:00Z", "2026-10-13T11:00:00Z", "A", "B"),
					iv("2026-10-13T11:00:00Z", "2026-10-13T12:00:00Z", "B", "C"),
				},
			}},
		},
		{
			name: "three at once names all three",
			zone: time.UTC,
			days: []WorkspaceDay{
				wday("A", "2026-10-13", ent(EntryApproved, 60, sp("2026-10-13T09:00:00Z", "2026-10-13T10:00:00Z"))),
				wday("B", "2026-10-13", ent(EntryApproved, 60, sp("2026-10-13T09:00:00Z", "2026-10-13T10:00:00Z"))),
				wday("C", "2026-10-13", ent(EntryApproved, 60, sp("2026-10-13T09:00:00Z", "2026-10-13T10:00:00Z"))),
			},
			want: map[string]wantDay{"2026-10-13": {
				Totals:    Totals{Reported: 180, Actual: 60, Overlap: 120},
				intervals: []OverlapInterval{iv("2026-10-13T09:00:00Z", "2026-10-13T10:00:00Z", "A", "B", "C")},
			}},
		},
		{
			name: "across midnight in Europe/Helsinki splits at the person's midnight",
			zone: hki,
			days: []WorkspaceDay{
				// 22:00..02:00 local (EEST, UTC+3)
				wday("A", "2026-10-13", ent(EntryApproved, 240, sp("2026-10-13T19:00:00Z", "2026-10-13T23:00:00Z"))),
			},
			want: map[string]wantDay{
				"2026-10-13": {Totals: Totals{Reported: 120, Actual: 120}},
				"2026-10-14": {Totals: Totals{Reported: 120, Actual: 120}},
			},
		},
		{
			name: "two zones: a UTC workspace re-bucketed to UTC+3, its unplaced row stays on its date",
			zone: hki,
			days: []WorkspaceDay{
				wday("A", "2026-10-13",
					ent(EntryApproved, 120, sp("2026-10-13T21:00:00Z", "2026-10-13T23:00:00Z")),
					ent(EntryApproved, 30)),
				wday("B", "2026-10-14", ent(EntryApproved, 60, sp("2026-10-13T22:00:00Z", "2026-10-13T23:00:00Z"))),
			},
			want: map[string]wantDay{
				"2026-10-13": {Totals: Totals{Reported: 30, Actual: 30, Unplaced: 30}, approx: true},
				"2026-10-14": {
					Totals:    Totals{Reported: 180, Actual: 120, Overlap: 60},
					intervals: []OverlapInterval{iv("2026-10-13T22:00:00Z", "2026-10-13T23:00:00Z", "A", "B")},
				},
			},
		},
		{
			name: "DST March: the 23 h day",
			zone: hki,
			days: []WorkspaceDay{
				wday("A", "2026-03-29", ent(EntryApproved, 660, sp("2026-03-28T22:00:00Z", "2026-03-29T09:00:00Z"))),
				wday("B", "2026-03-29", ent(EntryApproved, 720, sp("2026-03-29T09:00:00Z", "2026-03-29T21:00:00Z"))),
			},
			want: map[string]wantDay{"2026-03-29": {Totals: Totals{Reported: 1380, Actual: 1380}}},
		},
		{
			name: "DST October: the 25 h day",
			zone: hki,
			days: []WorkspaceDay{
				wday("A", "2026-10-25", ent(EntryApproved, 780, sp("2026-10-24T21:00:00Z", "2026-10-25T10:00:00Z"))),
				wday("B", "2026-10-25", ent(EntryApproved, 780, sp("2026-10-25T09:00:00Z", "2026-10-25T22:00:00Z"))),
			},
			want: map[string]wantDay{"2026-10-25": {
				Totals:    Totals{Reported: 1560, Actual: 1500, Overlap: 60},
				intervals: []OverlapInterval{iv("2026-10-25T09:00:00Z", "2026-10-25T10:00:00Z", "A", "B")},
			}},
		},
		{
			name: "unplaced minutes: approx, added in full",
			zone: time.UTC,
			days: []WorkspaceDay{
				wday("A", "2026-10-13", ent(EntryApproved, 120, sp("2026-10-13T09:00:00Z", "2026-10-13T11:00:00Z"))),
				wday("B", "2026-10-13", ent(EntryApproved, 60)),
			},
			want: map[string]wantDay{"2026-10-13": {Totals: Totals{Reported: 180, Actual: 180, Unplaced: 60}, approx: true}},
		},
		{
			name: "minutes edited down: earliest span first, the last one cut short",
			zone: time.UTC,
			days: []WorkspaceDay{
				wday("A", "2026-10-13", ent(EntryApproved, 90,
					sp("2026-10-13T11:00:00Z", "2026-10-13T12:00:00Z"),
					sp("2026-10-13T09:00:00Z", "2026-10-13T10:00:00Z"))),
				wday("B", "2026-10-13", ent(EntryApproved, 60, sp("2026-10-13T11:00:00Z", "2026-10-13T12:00:00Z"))),
			},
			want: map[string]wantDay{"2026-10-13": {
				Totals:    Totals{Reported: 150, Actual: 120, Overlap: 30},
				intervals: []OverlapInterval{iv("2026-10-13T11:00:00Z", "2026-10-13T11:30:00Z", "A", "B")},
			}},
		},
		{
			name: "minutes edited up: the rest is unplaced",
			zone: time.UTC,
			days: []WorkspaceDay{
				wday("A", "2026-10-13", ent(EntryApproved, 150, sp("2026-10-13T09:00:00Z", "2026-10-13T11:00:00Z"))),
				wday("B", "2026-10-13", ent(EntryApproved, 60, sp("2026-10-13T10:00:00Z", "2026-10-13T11:00:00Z"))),
			},
			want: map[string]wantDay{"2026-10-13": {
				Totals:    Totals{Reported: 210, Actual: 150, Overlap: 60, Unplaced: 30},
				approx:    true,
				intervals: []OverlapInterval{iv("2026-10-13T10:00:00Z", "2026-10-13T11:00:00Z", "A", "B")},
			}},
		},
		{
			name: "a rejected row counts 0",
			zone: time.UTC,
			days: []WorkspaceDay{
				wday("A", "2026-10-13", ent(EntryRejected, 120, sp("2026-10-13T09:00:00Z", "2026-10-13T11:00:00Z"))),
				wday("B", "2026-10-13", ent(EntryApproved, 120, sp("2026-10-13T10:00:00Z", "2026-10-13T12:00:00Z"))),
			},
			want: map[string]wantDay{"2026-10-13": {Totals: Totals{Reported: 120, Actual: 120}}},
		},
		{
			name: "data_error_minutes: two spans of one workspace overlap (old data)",
			zone: time.UTC,
			days: []WorkspaceDay{
				wday("A", "2026-10-13",
					ent(EntryApproved, 120, sp("2026-10-13T09:00:00Z", "2026-10-13T11:00:00Z")),
					ent(EntryApproved, 120, sp("2026-10-13T10:00:00Z", "2026-10-13T12:00:00Z"))),
			},
			want: map[string]wantDay{"2026-10-13": {Totals: Totals{Reported: 240, Actual: 180, Overlap: 60, DataErrorMinutes: 60}}},
		},
		{
			name: "open suggestions count in reported and in open",
			zone: time.UTC,
			days: []WorkspaceDay{
				wday("A", "2026-10-13", ent(EntryOpen, 60, sp("2026-10-13T09:00:00Z", "2026-10-13T10:00:00Z"))),
				wday("B", "2026-10-13", ent(EntryApproved, 60, sp("2026-10-13T09:30:00Z", "2026-10-13T10:30:00Z"))),
			},
			want: map[string]wantDay{"2026-10-13": {
				Totals:    Totals{Reported: 120, Open: 60, Actual: 90, Overlap: 30},
				intervals: []OverlapInterval{iv("2026-10-13T09:30:00Z", "2026-10-13T10:00:00Z", "A", "B")},
			}},
		},
		{
			name: "left workspace: receipt rows count as unplaced",
			zone: time.UTC,
			days: []WorkspaceDay{
				wday("A", "2026-10-13", ent(EntryApproved, 60, sp("2026-10-13T09:00:00Z", "2026-10-13T10:00:00Z"))),
				{Workspace: "B", Day: "2026-10-13", State: "left", Entries: []AcrossEntry{ent(EntryApproved, 45)}},
			},
			want: map[string]wantDay{"2026-10-13": {Totals: Totals{Reported: 105, Actual: 105, Unplaced: 45}, approx: true}},
		},
		{
			name: "workspace unavailable: computed over the rest",
			zone: time.UTC,
			days: []WorkspaceDay{
				wday("A", "2026-10-13", ent(EntryApproved, 60, sp("2026-10-13T09:00:00Z", "2026-10-13T10:00:00Z"))),
				unavailable,
			},
			want: map[string]wantDay{"2026-10-13": {Totals: Totals{Reported: 60, Actual: 60}}},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			got, err := Across(tc.days, tc.zone, utc("2026-10-13T18:00:00Z"))
			if err != nil {
				t.Fatal(err)
			}
			checkDays(t, got, tc.want)
		})
	}

	got, err := Across([]WorkspaceDay{unavailable}, time.UTC, utc("2026-10-13T18:00:00Z"))
	if err != nil {
		t.Fatal(err)
	}
	if !got[0].Incomplete || !slices.Equal(got[0].Unavailable, []string{"B"}) {
		t.Errorf("unavailable B: incomplete %v unavailable %v", got[0].Incomplete, got[0].Unavailable)
	}
}

// The open timer: [start, now) in actual and in the intervals, never in
// reported; split at the person's midnight; nothing before it starts.
func TestAcrossTimer(t *testing.T) {
	start := utc("2026-10-13T23:30:00Z")
	days := []WorkspaceDay{{Workspace: "A", Day: "2026-10-13", Timer: &start}}
	got, err := Across(days, time.UTC, utc("2026-10-14T00:30:00Z"))
	if err != nil {
		t.Fatal(err)
	}
	checkDays(t, got, map[string]wantDay{
		"2026-10-13": {Totals: Totals{Actual: 30}},
		"2026-10-14": {Totals: Totals{Actual: 30}},
	})
	if sp := got[1].Workspaces["A"].Spans; len(sp) != 1 || !sp[0].Provisional {
		t.Errorf("timer span %+v, want one provisional", sp)
	}
	got, err = Across(days, time.UTC, start.Add(-time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	checkDays(t, got, map[string]wantDay{"2026-10-13": {}})
}

// T-OV-RO: a return and a resubmit show on the next read; Across keeps
// nothing between calls, and no migration stores a computed total.
func TestAcrossTOVRO(t *testing.T) {
	read := func(state string, minutes int) []PersonalDay {
		t.Helper()
		got, err := Across([]WorkspaceDay{
			wday("A", "2026-10-13", ent(state, minutes, sp("2026-10-13T09:00:00Z", "2026-10-13T11:00:00Z"))),
			wday("B", "2026-10-13", ent(EntryApproved, 120, sp("2026-10-13T10:00:00Z", "2026-10-13T12:00:00Z"))),
		}, time.UTC, utc("2026-10-13T18:00:00Z"))
		if err != nil {
			t.Fatal(err)
		}
		return got
	}
	approved := read(EntryApproved, 120)
	checkDays(t, approved, map[string]wantDay{"2026-10-13": {
		Totals:    Totals{Reported: 240, Actual: 180, Overlap: 60},
		intervals: []OverlapInterval{iv("2026-10-13T10:00:00Z", "2026-10-13T11:00:00Z", "A", "B")},
	}})
	checkDays(t, read(EntryRejected, 120), map[string]wantDay{"2026-10-13": {Totals: Totals{Reported: 120, Actual: 120}}})
	// resubmitted as 60 open minutes: placed 09:00..10:00, touching B
	checkDays(t, read(EntryOpen, 60), map[string]wantDay{"2026-10-13": {Totals: Totals{Reported: 180, Open: 60, Actual: 180}}})
	if again := read(EntryApproved, 120); !reflect.DeepEqual(again, approved) {
		t.Errorf("second read %+v, first %+v", again, approved)
	}

	stored := regexp.MustCompile(`(?i)\b(actual|overlap|reported)[a-z_]*\s+(int|integer|smallint|bigint|numeric)\b`)
	if !stored.MatchString("  overlap_minutes integer NOT NULL") {
		t.Fatal("control: the pattern misses a planted total column")
	}
	// go test runs in the package dir; runtime.Caller's file is module-relative under -trimpath (SPL-3171)
	sqlDir := filepath.Join("..", "..", "..", "..", "..", "..",
		"csi-spl-rdb", "src", "sql", "postgres", "spool-hub")
	files, err := filepath.Glob(filepath.Join(sqlDir, "*.sql"))
	if err != nil || len(files) == 0 {
		t.Fatalf("migrations in %s: %d, %v", sqlDir, len(files), err)
	}
	for _, f := range files {
		body, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		for i, line := range strings.Split(string(body), "\n") {
			if stored.MatchString(line) {
				t.Errorf("%s:%d stores a computed total: %s", filepath.Base(f), i+1, line)
			}
		}
	}
}

func TestAcrossSum(t *testing.T) {
	got, err := Across([]WorkspaceDay{
		wday("A", "2026-10-13", ent(EntryApproved, 120, sp("2026-10-13T09:00:00Z", "2026-10-13T11:00:00Z"))),
		wday("B", "2026-10-13", ent(EntryApproved, 60, sp("2026-10-13T10:00:00Z", "2026-10-13T11:00:00Z"))),
		wday("A", "2026-10-14", ent(EntryOpen, 30)),
	}, time.UTC, utc("2026-10-14T18:00:00Z"))
	if err != nil {
		t.Fatal(err)
	}
	want := Totals{Reported: 210, Open: 30, Actual: 150, Overlap: 60, Unplaced: 30}
	if s := Sum(got); s != want {
		t.Errorf("Sum %+v, want %+v", s, want)
	}
}

func TestAcrossRefuses(t *testing.T) {
	now := utc("2026-10-13T18:00:00Z")
	if _, err := Across(nil, nil, now); err == nil {
		t.Error("nil zone: no error")
	}
	for name, wd := range map[string]WorkspaceDay{
		"bad day":    wday("A", "13.10.2026"),
		"bad state":  wday("A", "2026-10-13", ent("maybe", 60)),
		"negative":   wday("A", "2026-10-13", ent(EntryApproved, -1)),
		"empty span": wday("A", "2026-10-13", ent(EntryApproved, 60, sp("2026-10-13T09:00:00Z", "2026-10-13T09:00:00Z"))),
		"inside out": wday("A", "2026-10-13", ent(EntryApproved, 60, sp("2026-10-13T10:00:00Z", "2026-10-13T09:00:00Z"))),
	} {
		if _, err := Across([]WorkspaceDay{wd}, time.UTC, now); err == nil {
			t.Errorf("%s: no error", name)
		}
	}
	if got, err := Across(nil, time.UTC, now); err != nil || len(got) != 0 {
		t.Errorf("no days: %v, %v", got, err)
	}
}

// T-OV-JS (Go half): testdata/overlap_fixture.json, shared with the WUI.
func TestAcrossFixture(t *testing.T) {
	raw, err := os.ReadFile(filepath.Join("testdata", "overlap_fixture.json"))
	if err != nil {
		t.Fatal(err)
	}
	var fx struct {
		Cases []struct {
			Name string          `json:"name"`
			Zone string          `json:"zone"`
			Now  time.Time       `json:"now"`
			Days []WorkspaceDay  `json:"days"`
			Want json.RawMessage `json:"want"`
		} `json:"cases"`
	}
	if err := json.Unmarshal(raw, &fx); err != nil {
		t.Fatal(err)
	}
	if len(fx.Cases) == 0 {
		t.Fatal("fixture has no cases")
	}
	for _, c := range fx.Cases {
		t.Run(c.Name, func(t *testing.T) {
			zone, err := time.LoadLocation(c.Zone)
			if err != nil {
				t.Fatal(err)
			}
			got, err := Across(c.Days, zone, c.Now)
			if err != nil {
				t.Fatal(err)
			}
			gotJSON, err := json.Marshal(got)
			if err != nil {
				t.Fatal(err)
			}
			var g, w any
			if err := json.Unmarshal(gotJSON, &g); err != nil {
				t.Fatal(err)
			}
			if err := json.Unmarshal(c.Want, &w); err != nil {
				t.Fatal(err)
			}
			if !reflect.DeepEqual(g, w) {
				t.Errorf("got  %s\nwant %s", gotJSON, c.Want)
			}
		})
	}
}

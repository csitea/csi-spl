// SPDX-License-Identifier: AGPL-3.0-only

package hours

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestAcross(t *testing.T) {
	tzUTC := time.UTC
	tzBerlin, _ := time.LoadLocation("Europe/Berlin")
	now := time.Date(2026, 10, 13, 12, 0, 0, 0, time.UTC)

	testEmpty := struct {
		name     string
		days     []WorkspaceDay
		zone     *time.Location
		want     []PersonalDay
		wantErr  bool
	}{
		name:    "empty",
		days:    []WorkspaceDay{},
		zone:    tzUTC,
		want:    []PersonalDay{},
		wantErr: false,
	}

	testSingleWorkspace := struct {
		name     string
		days     []WorkspaceDay
		zone     *time.Location
		want     []PersonalDay
		wantErr  bool
	}{
		name: "single workspace, no overlap",
		days: []WorkspaceDay{
			{
				WorkspaceID: "ws:1",
				Date:        "2026-10-13",
				Entries: []Entry{
					{
						Start:    timePtr(time.Date(2026, 10, 13, 9, 0, 0, 0, tzUTC)),
						End:      timePtr(time.Date(2026, 10, 13, 10, 0, 0, 0, tzUTC)),
						Minutes:  60,
						Unplaced: 0,
					},
				},
				State: "ok",
			},
		},
		zone: tzUTC,
		want: []PersonalDay{
			{
				Date:     "2026-10-13",
				Reported: 60,
				Actual:   60,
				Overlap:  0,
				Workspaces: map[string]WorkspaceDayResult{
					"ws:1": {Reported: 60, Actual: 60, Spans: []TimeSpan{{Start: time.Date(2026, 10, 13, 9, 0, 0, 0, tzUTC), End: time.Date(2026, 10, 13, 10, 0, 0, 0, tzUTC)}}},
				},
			},
		},
		wantErr: false,
	}

	testTwoWorkspacesNoOverlap := struct {
		name     string
		days     []WorkspaceDay
		zone     *time.Location
		want     []PersonalDay
		wantErr  bool
	}{
		name: "two workspaces, no overlap",
		days: []WorkspaceDay{
			{
				WorkspaceID: "ws:1",
				Date:        "2026-10-13",
				Entries: []Entry{
					{
						Start:    timePtr(time.Date(2026, 10, 13, 9, 0, 0, 0, tzUTC)),
						End:      timePtr(time.Date(2026, 10, 13, 10, 0, 0, 0, tzUTC)),
						Minutes:  60,
						Unplaced: 0,
					},
				},
				State: "ok",
			},
			{
				WorkspaceID: "ws:2",
				Date:        "2026-10-13",
				Entries: []Entry{
					{
						Start:    timePtr(time.Date(2026, 10, 13, 11, 0, 0, 0, tzUTC)),
						End:      timePtr(time.Date(2026, 10, 13, 12, 0, 0, 0, tzUTC)),
						Minutes:  60,
						Unplaced: 0,
					},
				},
				State: "ok",
			},
		},
		zone: tzUTC,
		want: []PersonalDay{
			{
				Date:     "2026-10-13",
				Reported: 120,
				Actual:   120,
				Overlap:  0,
				Workspaces: map[string]WorkspaceDayResult{
					"ws:1": {Reported: 60, Actual: 60, Spans: []TimeSpan{{Start: time.Date(2026, 10, 13, 9, 0, 0, 0, tzUTC), End: time.Date(2026, 10, 13, 10, 0, 0, 0, tzUTC)}}},
					"ws:2": {Reported: 60, Actual: 60, Spans: []TimeSpan{{Start: time.Date(2026, 10, 13, 11, 0, 0, 0, tzUTC), End: time.Date(2026, 10, 13, 12, 0, 0, 0, tzUTC)}}},
				},
			},
		},
		wantErr: false,
	}

	testTwoWorkspacesOverlap := struct {
		name     string
		days     []WorkspaceDay
		zone     *time.Location
		want     []PersonalDay
		wantErr  bool
	}{
		name: "two workspaces, overlap",
		days: []WorkspaceDay{
			{
				WorkspaceID: "ws:1",
				Date:        "2026-10-13",
				Entries: []Entry{
					{
						Start:    timePtr(time.Date(2026, 10, 13, 9, 0, 0, 0, tzUTC)),
						End:      timePtr(time.Date(2026, 10, 13, 11, 0, 0, 0, tzUTC)),
						Minutes:  120,
						Unplaced: 0,
					},
				},
				State: "ok",
			},
			{
				WorkspaceID: "ws:2",
				Date:        "2026-10-13",
				Entries: []Entry{
					{
						Start:    timePtr(time.Date(2026, 10, 13, 10, 0, 0, 0, tzUTC)),
						End:      timePtr(time.Date(2026, 10, 13, 12, 0, 0, 0, tzUTC)),
						Minutes:  120,
						Unplaced: 0,
					},
				},
				State: "ok",
			},
		},
		zone: tzUTC,
		want: []PersonalDay{
			{
				Date:     "2026-10-13",
				Reported: 240,
				Actual:   180,
				Overlap:  60,
				Workspaces: map[string]WorkspaceDayResult{
					"ws:1": {Reported: 120, Actual: 120, Spans: []TimeSpan{{Start: time.Date(2026, 10, 13, 9, 0, 0, 0, tzUTC), End: time.Date(2026, 10, 13, 11, 0, 0, 0, tzUTC)}}},
					"ws:2": {Reported: 120, Actual: 120, Spans: []TimeSpan{{Start: time.Date(2026, 10, 13, 10, 0, 0, 0, tzUTC), End: time.Date(2026, 10, 13, 12, 0, 0, 0, tzUTC)}}},
				},
			},
		},
		wantErr: false,
	}

	testMidnightSplit := struct {
		name     string
		days     []WorkspaceDay
		zone     *time.Location
		want     []PersonalDay
		wantErr  bool
	}{
		name: "midnight split",
		days: []WorkspaceDay{
			{
				WorkspaceID: "ws:1",
				Date:        "2026-10-13",
				Entries: []Entry{
					{
						Start:    timePtr(time.Date(2026, 10, 13, 23, 0, 0, 0, tzUTC)),
						End:      timePtr(time.Date(2026, 10, 14, 1, 0, 0, 0, tzUTC)),
						Minutes:  120,
						Unplaced: 0,
					},
				},
				State: "ok",
			},
		},
		zone: tzUTC,
		want: []PersonalDay{
			{
				Date:     "2026-10-13",
				Reported: 60,
				Actual:   60,
				Overlap:  0,
				Workspaces: map[string]WorkspaceDayResult{
					"ws:1": {Reported: 60, Actual: 60, Spans: []TimeSpan{{Start: time.Date(2026, 10, 13, 23, 0, 0, 0, tzUTC), End: time.Date(2026, 10, 14, 0, 0, 0, 0, tzUTC)}}},
				},
			},
			{
				Date:     "2026-10-14",
				Reported: 60,
				Actual:   60,
				Overlap:  0,
				Workspaces: map[string]WorkspaceDayResult{
					"ws:1": {Reported: 60, Actual: 60, Spans: []TimeSpan{{Start: time.Date(2026, 10, 14, 0, 0, 0, 0, tzUTC), End: time.Date(2026, 10, 14, 1, 0, 0, 0, tzUTC)}}},
				},
			},
		},
		wantErr: false,
	}

	testDST := struct {
		name     string
		days     []WorkspaceDay
		zone     *time.Location
		want     []PersonalDay
		wantErr  bool
	}{
		name: "DST transition (Berlin, spring forward)",
		days: []WorkspaceDay{
			{
				WorkspaceID: "ws:1",
				Date:        "2026-03-29", // DST starts in Berlin
				Entries: []Entry{
					{
						Start:    timePtr(time.Date(2026, 3, 29, 1, 30, 0, 0, tzBerlin)),
						End:      timePtr(time.Date(2026, 3, 29, 3, 30, 0, 0, tzBerlin)),
						Minutes:  120,
						Unplaced: 0,
					},
				},
				State: "ok",
			},
		},
		zone: tzBerlin,
		want: []PersonalDay{
			{
				Date:     "2026-03-29",
				Reported: 120,
				Actual:   60, // 1:30-3:00 in DST is 1.5h wall-clock, but 1h in UTC+2
				Overlap:  60,
				Workspaces: map[string]WorkspaceDayResult{
					"ws:1": {Reported: 120, Actual: 60, Spans: []TimeSpan{{Start: time.Date(2026, 3, 29, 1, 30, 0, 0, tzBerlin), End: time.Date(2026, 3, 29, 3, 0, 0, 0, tzBerlin)}}},
				},
			},
		},
		wantErr: false,
	}

	testUnplaced := struct {
		name     string
		days     []WorkspaceDay
		zone     *time.Location
		want     []PersonalDay
		wantErr  bool
	}{
		name: "unplaced minutes",
		days: []WorkspaceDay{
			{
				WorkspaceID: "ws:1",
				Date:        "2026-10-13",
				Entries: []Entry{
					{
						Start:    nil,
						End:      nil,
						Minutes:  60,
						Unplaced: 60,
					},
				},
				State: "ok",
			},
		},
		zone: tzUTC,
		want: []PersonalDay{
			{
				Date:     "2026-10-13",
				Reported: 60,
				Actual:   60,
				Overlap:  0,
				Workspaces: map[string]WorkspaceDayResult{
					"ws:1": {Reported: 60, Actual: 60},
				},
			},
		},
		wantErr: false,
	}

	testReceipts := struct {
		name     string
		days     []WorkspaceDay
		zone     *time.Location
		want     []PersonalDay
		wantErr  bool
	}{
		name: "left-workspace receipts",
		days: []WorkspaceDay{
			{
				WorkspaceID: "ws:1",
				Date:        "2026-10-13",
				Receipts: []Receipt{
					{Minutes: 60, Approver: "user:1"},
				},
				State: "ok",
			},
		},
		zone: tzUTC,
		want: []PersonalDay{
			{
				Date:     "2026-10-13",
				Reported: 60,
				Actual:   60,
				Overlap:  0,
				Workspaces: map[string]WorkspaceDayResult{
					"ws:1": {Reported: 60, Actual: 60},
				},
			},
		},
		wantErr: false,
	}

	testUnavailable := struct {
		name     string
		days     []WorkspaceDay
		zone     *time.Location
		want     []PersonalDay
		wantErr  bool
	}{
		name: "unavailable workspace",
		days: []WorkspaceDay{
			{
				WorkspaceID: "ws:1",
				Date:        "2026-10-13",
				State:       "unavailable",
			},
		},
		zone: tzUTC,
		want: []PersonalDay{
			{
				Date:     "2026-10-13",
				Reported: 0,
				Actual:   0,
				Overlap:  0,
				Workspaces: map[string]WorkspaceDayResult{
					"ws:1": {Reported: 0, Actual: 0},
				},
			},
		},
		wantErr: false,
	}

	testDifferentZones := struct {
		name     string
		days     []WorkspaceDay
		zone     *time.Location
		want     []PersonalDay
		wantErr  bool
	}{
		name: "different zones (UTC -> Berlin)",
		days: []WorkspaceDay{
			{
				WorkspaceID: "ws:1",
				Date:        "2026-10-13", // 2026-10-13 in UTC is 2026-10-13 in Berlin
				Entries: []Entry{
					{
						Start:    timePtr(time.Date(2026, 10, 13, 23, 0, 0, 0, tzUTC)),
						End:      timePtr(time.Date(2026, 10, 14, 1, 0, 0, 0, tzUTC)),
						Minutes:  120,
						Unplaced: 0,
					},
				},
				State: "ok",
			},
		},
		zone: tzBerlin,
		want: []PersonalDay{
			{
				Date:     "2026-10-14", // 23:00-01:00 UTC is 00:00-02:00 Berlin
				Reported: 120,
				Actual:   120,
				Overlap:  0,
				Workspaces: map[string]WorkspaceDayResult{
					"ws:1": {Reported: 120, Actual: 120, Spans: []TimeSpan{{Start: time.Date(2026, 10, 14, 0, 0, 0, 0, tzBerlin), End: time.Date(2026, 10, 14, 2, 0, 0, 0, tzBerlin)}}},
				},
			},
		},
		wantErr: false,
	}

	testOpenTimer := struct {
		name     string
		days     []WorkspaceDay
		zone     *time.Location
		want     []PersonalDay
		wantErr  bool
	}{
		name: "open timer (provisional in actual, not in reported)",
		days: []WorkspaceDay{
			{
				WorkspaceID: "ws:1",
				Date:        "2026-10-13",
				Entries: []Entry{
					{
						Start:    timePtr(time.Date(2026, 10, 13, 9, 0, 0, 0, tzUTC)),
						End:      nil, // open timer
						Minutes:  180, // 9:00-12:00 (provisional)
						Unplaced: 0,
					},
				},
				State: "ok",
			},
		},
		zone: tzUTC,
		want: []PersonalDay{
			{
				Date:     "2026-10-13",
				Reported: 0, // open timer not counted in reported
				Actual:   180, // provisional in actual
				Overlap:  0,
				Workspaces: map[string]WorkspaceDayResult{
					"ws:1": {Reported: 0, Actual: 180, Spans: []TimeSpan{{Start: time.Date(2026, 10, 13, 9, 0, 0, 0, tzUTC), End: now}}},
				},
			},
		},
		wantErr: false,
	}

	testNoZone := struct {
		name     string
		days     []WorkspaceDay
		zone     *time.Location
		want     []PersonalDay
		wantErr  bool
	}{
		name: "no time zone",
		days: []WorkspaceDay{
			{
				WorkspaceID: "ws:1",
				Date:        "2026-10-13",
				Entries: []Entry{
					{Minutes: 60},
				},
				State: "ok",
			},
		},
		zone: nil,
		want:    nil,
		wantErr: true,
	}

	tests := []struct {
		name     string
		days     []WorkspaceDay
		zone     *time.Location
		want     []PersonalDay
		wantErr  bool
	}{
		testEmpty,
		testSingleWorkspace,
		testTwoWorkspacesNoOverlap,
		testTwoWorkspacesOverlap,
		testMidnightSplit,
		testDST,
		testUnplaced,
		testReceipts,
		testUnavailable,
		testDifferentZones,
		testOpenTimer,
		testNoZone,
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := Across(tt.days, tt.zone, now)
			if (err != nil) != tt.wantErr {
				t.Errorf("Across() error = %v, wantErr %v", err, tt.wantErr)
				return
			}
			if err != nil {
				return
			}
			if len(got) != len(tt.want) {
				t.Errorf("Across() len = %v, want %v", len(got), len(tt.want))
				return
			}
			for i, g := range got {
				w := tt.want[i]
				if g.Date != w.Date {
					t.Errorf("Across()[%d].Date = %v, want %v", i, g.Date, w.Date)
				}
				if g.Reported != w.Reported {
					t.Errorf("Across()[%d].Reported = %v, want %v", i, g.Reported, w.Reported)
				}
				if g.Actual != w.Actual {
					t.Errorf("Across()[%d].Actual = %v, want %v", i, g.Actual, w.Actual)
				}
				if g.Overlap != w.Overlap {
					t.Errorf("Across()[%d].Overlap = %v, want %v", i, g.Overlap, w.Overlap)
				}
				if len(g.Workspaces) != len(w.Workspaces) {
					t.Errorf("Across()[%d].Workspaces len = %v, want %v", i, len(g.Workspaces), len(w.Workspaces))
				}
				for ws, gw := range g.Workspaces {
					ww, ok := w.Workspaces[ws]
					if !ok {
						t.Errorf("Across()[%d].Workspaces[%q] missing", i, ws)
						continue
					}
					if gw.Reported != ww.Reported {
						t.Errorf("Across()[%d].Workspaces[%q].Reported = %v, want %v", i, ws, gw.Reported, ww.Reported)
					}
					if gw.Actual != ww.Actual {
						t.Errorf("Across()[%d].Workspaces[%q].Actual = %v, want %v", i, ws, gw.Actual, ww.Actual)
					}
					if len(gw.Spans) != len(ww.Spans) {
						t.Errorf("Across()[%d].Workspaces[%q].Spans len = %v, want %v", i, ws, len(gw.Spans), len(ww.Spans))
					}
					for j := range gw.Spans {
						if j >= len(ww.Spans) {
							break
						}
						if !gw.Spans[j].Start.Equal(ww.Spans[j].Start) || !gw.Spans[j].End.Equal(ww.Spans[j].End) {
							t.Errorf("Across()[%d].Workspaces[%q].Spans[%d] mismatch", i, ws, j)
						}
						}
					}
				}
			})
	}
}

func TestAcross_Fixture(t *testing.T) {
	// Load the shared fixture.
	fixturePath := filepath.Join("testdata", "overlap_fixture.json")
	fixtureData, err := os.ReadFile(fixturePath)
	if err != nil {
		if os.IsNotExist(err) {
			t.Skip("fixture not found, skipping")
		}
		t.Fatalf("failed to read fixture: %v", err)
	}

	var fixture struct {
		Days []struct {
			WorkspaceID string   `json:"workspace_id"`
			Date        string   `json:"date"`
			Entries     []Entry  `json:"entries"`
			Receipts    []Receipt `json:"receipts"`
			State       string   `json:"state"`
		} `json:"days"`
		Zone string        `json:"zone"`
		Now  time.Time     `json:"now"`
		Want []PersonalDay `json:"want"`
	}
	if err := json.Unmarshal(fixtureData, &fixture); err != nil {
		t.Fatalf("failed to unmarshal fixture: %v", err)
	}

	// Convert fixture.Days to []WorkspaceDay.
	days := make([]WorkspaceDay, 0, len(fixture.Days))
	for _, d := range fixture.Days {
		days = append(days, WorkspaceDay{
			WorkspaceID: d.WorkspaceID,
			Date:        d.Date,
			Entries:     d.Entries,
			Receipts:    d.Receipts,
			State:       d.State,
		})
	}

	// Call Across with the fixture data.
	zone, err := time.LoadLocation(fixture.Zone)
	if err != nil {
		t.Fatalf("failed to load zone %q: %v", fixture.Zone, err)
	}
	got, err := Across(days, zone, fixture.Now)
	if err != nil {
		t.Fatalf("Across() error = %v", err)
	}

	// Compare got and want.
	want := fixture.Want
	if len(got) != len(want) {
		t.Errorf("Across() len = %v, want %v", len(got), len(want))
		return
	}
	for i, g := range got {
		w := want[i]
		if g.Date != w.Date {
			t.Errorf("Across()[%d].Date = %v, want %v", i, g.Date, w.Date)
		}
		if g.Reported != w.Reported {
			t.Errorf("Across()[%d].Reported = %v, want %v", i, g.Reported, w.Reported)
		}
		if g.Actual != w.Actual {
			t.Errorf("Across()[%d].Actual = %v, want %v", i, g.Actual, w.Actual)
		}
		if g.Overlap != w.Overlap {
			t.Errorf("Across()[%d].Overlap = %v, want %v", i, g.Overlap, w.Overlap)
		}
		if len(g.Workspaces) != len(w.Workspaces) {
			t.Errorf("Across()[%d].Workspaces len = %v, want %v", i, len(g.Workspaces), len(w.Workspaces))
		}
		for ws, gw := range g.Workspaces {
			ww, ok := w.Workspaces[ws]
			if !ok {
				t.Errorf("Across()[%d].Workspaces[%q] missing", i, ws)
				continue
			}
			if gw.Reported != ww.Reported {
				t.Errorf("Across()[%d].Workspaces[%q].Reported = %v, want %v", i, ws, gw.Reported, ww.Reported)
			}
			if gw.Actual != ww.Actual {
				t.Errorf("Across()[%d].Workspaces[%q].Actual = %v, want %v", i, ws, gw.Actual, ww.Actual)
			}
			if len(gw.Spans) != len(ww.Spans) {
				t.Errorf("Across()[%d].Workspaces[%q].Spans len = %v, want %v", i, ws, len(gw.Spans), len(ww.Spans))
			}
			for j := range gw.Spans {
				if j >= len(ww.Spans) {
					break
				}
				if !gw.Spans[j].Start.Equal(ww.Spans[j].Start) || !gw.Spans[j].End.Equal(ww.Spans[j].End) {
					t.Errorf("Across()[%d].Workspaces[%q].Spans[%d] mismatch", i, ws, j)
				}
			}
		}
	}
}

// timePtr returns a pointer to t.
func timePtr(t time.Time) *time.Time {
	return &t
}
// SPDX-License-Identifier: AGPL-3.0-only

package hours

import (
	"slices"
	"testing"
	"time"
)

// Unit tests for three small helpers: minTime, appendInterval (the overlap
// stretch merger of sweep) and minuteOf (Unix minutes, floored). Times are UTC.

// imAt is 2026-10-07 hh:mm UTC.
func imAt(hh, mm int) time.Time {
	return time.Date(2026, 10, 7, hh, mm, 0, 0, time.UTC)
}

// imOpen is an open-workspace map with one stretch per name.
func imOpen(ws ...string) map[string]int {
	open := map[string]int{}
	for _, w := range ws {
		open[w] = 1
	}
	return open
}

func TestMinTime(t *testing.T) {
	early, late := imAt(9, 0), imAt(10, 0)
	cases := []struct {
		name string
		a, b time.Time
		want time.Time
	}{
		{"a before b", early, late, early},
		{"a after b", late, early, early},
		{"a equal b", early, imAt(9, 0), early},
	}
	for _, c := range cases {
		if got := minTime(c.a, c.b); !got.Equal(c.want) {
			t.Errorf("%s: minTime(%v, %v) = %v, want %v", c.name, c.a, c.b, got, c.want)
		}
	}
}

func TestAppendIntervalMergesAdjacentSameSet(t *testing.T) {
	out := []OverlapInterval{{Start: imAt(9, 0), End: imAt(9, 30), Workspaces: []string{"a", "b"}}}
	out = appendInterval(out, imAt(9, 30), imAt(10, 0), imOpen("b", "a"))
	if len(out) != 1 {
		t.Fatalf("len = %d, want 1 (merged in place): %+v", len(out), out)
	}
	if !out[0].Start.Equal(imAt(9, 0)) || !out[0].End.Equal(imAt(10, 0)) {
		t.Errorf("merged = %v..%v, want 09:00..10:00", out[0].Start, out[0].End)
	}
}

func TestAppendIntervalAppendsNew(t *testing.T) {
	prev := OverlapInterval{Start: imAt(9, 0), End: imAt(9, 30), Workspaces: []string{"a", "b"}}
	cases := []struct {
		name     string
		out      []OverlapInterval
		from, to time.Time
		open     map[string]int
		wantLen  int
	}{
		{"empty", nil, imAt(9, 30), imAt(10, 0), imOpen("b", "a"), 1},
		{"gap", []OverlapInterval{prev}, imAt(9, 45), imAt(10, 0), imOpen("a", "b"), 2},
		{"other set", []OverlapInterval{prev}, imAt(9, 30), imAt(10, 0), imOpen("a", "c"), 2},
	}
	for _, c := range cases {
		got := appendInterval(c.out, c.from, c.to, c.open)
		if len(got) != c.wantLen {
			t.Fatalf("%s: len = %d, want %d: %+v", c.name, len(got), c.wantLen, got)
		}
		last := got[len(got)-1]
		if !last.Start.Equal(c.from) || !last.End.Equal(c.to) {
			t.Errorf("%s: last = %v..%v, want %v..%v", c.name, last.Start, last.End, c.from, c.to)
		}
		if !slices.IsSorted(last.Workspaces) || len(last.Workspaces) != len(c.open) {
			t.Errorf("%s: workspaces = %v, want the %d open ones sorted", c.name, last.Workspaces, len(c.open))
		}
	}
}

func TestMinuteOf(t *testing.T) {
	cases := []struct {
		secs int64
		want int64
	}{
		{-1, -1},
		{-61, -2},
		{-60, -1},
		{0, 0},
		{61, 1},
	}
	for _, c := range cases {
		if got := minuteOf(time.Unix(c.secs, 0).UTC()); got != c.want {
			t.Errorf("minuteOf(Unix %d) = %d, want %d", c.secs, got, c.want)
		}
	}
}

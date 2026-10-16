package store

import (
	"context"
	"fmt"
	"testing"
	"time"
)

// SPL-2080 (found by c-226, SPL-2029): the bench hold reads 41 min of every
// box's beats (box = ""), about 246 rows per box at the 10 s tick. Capped at
// BoxBeatsMax in total, a third box cut the read to the newest 500 rows and
// every box read "recovering". The cap is per box now.

// seedBeats appends n beats of box, one per step, the newest at newest.
func seedBeats(t *testing.T, bb BoxBeats, tenant, box string, newest time.Time, step time.Duration, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		if err := bb.AppendBoxBeat(context.Background(), tenant, BoxBeat{Box: box, BeatAt: newest.Add(-time.Duration(i) * step), PID: 1}); err != nil {
			t.Fatal(err)
		}
	}
}

func beatsPerBox(rows []BoxBeat) map[string]int {
	out := map[string]int{}
	for _, b := range rows {
		out[b.Box]++
	}
	return out
}

// TestListBoxBeatsThreeBoxesFullWindow: 3 boxes x 41 min of 10 s beats read
// back whole, newest first. RED CONTROL: the rows outnumber BoxBeatsMax, so
// the old total cap returned 500 of them (measured: this test fails on it).
func TestListBoxBeatsThreeBoxesFullWindow(t *testing.T) {
	const window, step, perBox = 41 * time.Minute, 10 * time.Second, 246
	if 3*perBox <= BoxBeatsMax {
		t.Fatalf("RED CONTROL: %d rows fit the old total cap %d: the test proves nothing", 3*perBox, BoxBeatsMax)
	}
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			bb, ok := s.(BoxBeats)
			if !ok {
				t.Skip("no box beats")
			}
			tid := newTenant(t, s)
			now := time.Now().UTC().Truncate(time.Microsecond)
			for _, box := range []string{"box-a", "box-b", "box-c"} {
				seedBeats(t, bb, tid, box, now.Add(-5*time.Second), step, perBox)
			}
			rows, err := bb.ListBoxBeats(context.Background(), tid, "", now.Add(-window))
			if err != nil {
				t.Fatal(err)
			}
			if len(rows) != 3*perBox {
				t.Fatalf("read %d rows, want %d (per box %v)", len(rows), 3*perBox, beatsPerBox(rows))
			}
			for box, n := range beatsPerBox(rows) {
				if n != perBox {
					t.Errorf("%s: %d rows, want %d", box, n, perBox)
				}
			}
			for i := 1; i < len(rows); i++ {
				if rows[i].BeatAt.After(rows[i-1].BeatAt) {
					t.Fatalf("row %d (%v) is newer than row %d (%v): not newest first", i, rows[i].BeatAt, i-1, rows[i-1].BeatAt)
				}
			}
		})
	}
}

// TestListBoxBeatsCapPerBox: a box over the cap keeps its newest BoxBeatsMax
// rows and costs no other box a row. CONTROL: one box read alone is capped
// the same.
func TestListBoxBeatsCapPerBox(t *testing.T) {
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			bb, ok := s.(BoxBeats)
			if !ok {
				t.Skip("no box beats")
			}
			ctx := context.Background()
			tid := newTenant(t, s)
			now := time.Now().UTC().Truncate(time.Microsecond)
			seedBeats(t, bb, tid, "box-loud", now, time.Second, BoxBeatsMax+4)
			seedBeats(t, bb, tid, "box-calm", now, 10*time.Second, 3)
			since := now.Add(-time.Hour)
			for _, box := range []string{"", "box-loud"} {
				rows, err := bb.ListBoxBeats(ctx, tid, box, since)
				if err != nil {
					t.Fatal(err)
				}
				got := beatsPerBox(rows)
				want := map[string]int{"box-loud": BoxBeatsMax, "box-calm": 3}
				if box != "" {
					delete(want, "box-calm")
				}
				if fmt.Sprint(got) != fmt.Sprint(want) {
					t.Fatalf("box %q: per box %v, want %v", box, got, want)
				}
				oldest := now.Add(-time.Duration(BoxBeatsMax-1) * time.Second)
				for _, b := range rows {
					if b.Box == "box-loud" && b.BeatAt.Before(oldest) {
						t.Fatalf("box %q: kept %v, older than the newest %d", box, b.BeatAt, BoxBeatsMax)
					}
				}
			}
		})
	}
}

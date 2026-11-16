package store

import (
	"context"
	"errors"
	"testing"
	"time"
)

// SPL-4835 (R7 of SPL-4810, spec 153 section 3.20): a closed console's last
// masked screen is not served once its demand ended more than
// LaneConsoleKeep ago, even when no new demand came to delete the row.
// RED CONTROL: before the fix LaneConsoleOf read the row with no time
// bound, so the late read below returned the old screen.
func TestLaneConsoleOfPastKeepNotServed(t *testing.T) {
	ctx := context.Background()
	for name, s := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			cs, ok := s.(LaneConsoleStore)
			if !ok {
				t.Skip("no lane console")
			}
			tid := newTenant(t, s)
			now := time.Now().UTC().Truncate(time.Microsecond)
			until := now.Add(time.Minute)
			if _, err := cs.DemandLaneConsole(ctx, tid, "box-a", "c-001", "HUM-1", until, now); err != nil {
				t.Fatal(err)
			}
			if err := cs.PutLaneConsole(ctx, tid, "box-a", LaneConsoleShot{AgentID: "c-001", Screen: "old screen", Lines: 1}, now); err != nil {
				t.Fatal(err)
			}
			// CONTROL: within the keep the row and its screen are served.
			c, err := cs.LaneConsoleOf(ctx, tid, "box-a", "c-001", until.Add(LaneConsoleKeep-time.Second))
			if err != nil || c.Screen != "old screen" {
				t.Fatalf("within keep: %+v %v, want the screen", c, err)
			}
			late := until.Add(LaneConsoleKeep + time.Second)
			if c, err := cs.LaneConsoleOf(ctx, tid, "box-a", "c-001", late); !errors.Is(err, ErrNotFound) {
				t.Fatalf("past keep, no new demand: %+v %v, want ErrNotFound", c, err)
			}
			// The next demand still deletes the old row (delete-on-next-demand).
			if _, err := cs.DemandLaneConsole(ctx, tid, "box-a", "c-002", "HUM-1", late.Add(time.Minute), late); err != nil {
				t.Fatal(err)
			}
			if c, err := cs.LaneConsoleOf(ctx, tid, "box-a", "c-001", now); !errors.Is(err, ErrNotFound) {
				t.Fatalf("after the next demand: %+v %v, want the row deleted", c, err)
			}
		})
	}
}

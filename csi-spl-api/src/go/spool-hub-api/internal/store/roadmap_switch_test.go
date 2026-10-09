package store

import (
	"context"
	"errors"
	"sort"
	"strings"
	"testing"
)

// TestRoadmapSwitch (specs/112 HUB-2, spec 12.5; rdb 0162): a workspace
// roadmap starts internal; turning it public re-audiences that workspace's
// live synced goal:, spec: and release: events in the same write, never a
// db: event, a member's own event or another workspace's events; turning it
// back moves them back. Memory, and Postgres under SPOOL_TEST_PG_DSN.
func TestRoadmapSwitch(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			ctx := context.Background()
			rs, cs, cal := st.(RoadmapSwitch), st.(CalendarSync), st.(Calendar)
			a, b := newTenant(t, st), newTenant(t, st)
			batch := append(syncBatch(), syncEv("release:v1.3.0", "v1.3.0", "release", CalendarInternal))
			for i := range batch {
				if !strings.HasPrefix(batch[i].SourceKey, "db:") {
					batch[i].Event.Audience = RoadmapAudience(false)
				}
			}
			for _, tid := range []string{a, b} {
				if _, err := cs.UpsertCalendarBySourceKey(ctx, tid, batch, calT0); err != nil {
					t.Fatal(err)
				}
			}
			own, err := cal.CreateCalendarEvent(ctx, a, calEvent("mine"), calT0)
			if err != nil {
				t.Fatal(err)
			}
			if on, err := rs.RoadmapPublic(ctx, a); err != nil || on {
				t.Fatalf("CONTROL: fresh workspace: public=%v err=%v, want internal", on, err)
			}
			audiences := func(tid string) string {
				t.Helper()
				evs, err := st.(CalendarSourced).CalendarBySourceKey(ctx, tid, "", "")
				if err != nil {
					t.Fatal(err)
				}
				var out []string
				for _, e := range evs {
					out = append(out, e.SourceKey+"="+e.Audience)
				}
				sort.Strings(out)
				return strings.Join(out, ",")
			}
			internal := "db:t-0001=internal,goal:G01:deadline=internal,goal:G01:m:a=internal,release:v1.3.0=internal,spec:089:done=internal"
			if got := audiences(a); got != internal {
				t.Fatalf("before: %s", got)
			}
			n, err := rs.SetRoadmapPublic(ctx, a, true, calT0)
			if err != nil || n != 4 {
				t.Fatalf("turn public: n=%d err=%v, want 4", n, err)
			}
			public := "db:t-0001=internal,goal:G01:deadline=public,goal:G01:m:a=public,release:v1.3.0=public,spec:089:done=public"
			if on, _ := rs.RoadmapPublic(ctx, a); !on || audiences(a) != public {
				t.Fatalf("after public: on=%v %s", on, audiences(a))
			}
			if on, _ := rs.RoadmapPublic(ctx, b); on || audiences(b) != internal {
				t.Fatalf("turning a public moved b: on=%v %s", on, audiences(b))
			}
			if e, err := cal.GetCalendarEvent(ctx, a, calOwner, own.ID); err != nil || e.Audience != own.Audience {
				t.Fatalf("a member's own event moved: %+v %v", e, err)
			}
			if n, err := rs.SetRoadmapPublic(ctx, a, true, calT0); err != nil || n != 0 {
				t.Fatalf("again: n=%d err=%v, want 0", n, err)
			}
			if n, err := rs.SetRoadmapPublic(ctx, a, false, calT0); err != nil || n != 4 || audiences(a) != internal {
				t.Fatalf("CONTROL: back to internal: n=%d err=%v %s", n, err, audiences(a))
			}
			if _, err := rs.RoadmapPublic(ctx, "t-none"); !errors.Is(err, ErrNotFound) {
				t.Fatalf("no tenant read: %v", err)
			}
			if _, err := rs.SetRoadmapPublic(ctx, "t-none", true, calT0); !errors.Is(err, ErrNotFound) {
				t.Fatalf("no tenant write: %v", err)
			}
		})
	}
}

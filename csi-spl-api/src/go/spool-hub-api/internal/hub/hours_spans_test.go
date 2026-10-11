package hub_test

import (
	"context"
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Spec 107 v2.3 section 3.4 (spec 118 Q1 A, Q2 A): the timer and the approval
// keep their times as spans. Clock and weeks as hours_me_test.go.

func spansOf(t *testing.T, e *env, tid, hum, day string) []string {
	t.Helper()
	ss, err := hoursStore(e).HoursEntrySpans(context.Background(), tid, hum, day, day)
	if err != nil {
		t.Fatal(err)
	}
	out := []string{}
	for _, s := range ss {
		out = append(out, s.Target+" "+s.Start.Format("15:04")+"-"+s.End.Format("15:04")+" "+s.Src)
	}
	return out
}

// The stopped timer keeps its interval, split at midnight; approving a
// suggestion keeps its block; a typed row has none and stays valid; a timer
// over other times of the member is 409 overlap_in_workspace and writes
// nothing; another member has no spans.
func TestMyHoursSpans(t *testing.T) {
	e, tid := hoursEnv(t)
	a := seat(t, e, tid, rbac.Developer)
	b := seat(t, e, tid, rbac.Developer)

	if code, out := postTimer(t, e, tid, a, timerBody("ch:general", at("2026-10-05", 23, 30), at("2026-10-06", 0, 45))); code != http.StatusOK {
		t.Fatalf("stop: %d %v", code, out)
	}
	if got := spansOf(t, e, tid, a, "2026-10-05"); len(got) != 1 || got[0] != "ch:general 23:30-00:00 timer" {
		t.Fatalf("monday spans: %v", got)
	}
	if got := spansOf(t, e, tid, a, "2026-10-06"); len(got) != 1 || got[0] != "ch:general 00:00-00:45 timer" {
		t.Fatalf("tuesday spans: %v", got)
	}

	// 21 tab minutes from 09:00 suggest t:task-y with one block; approving it keeps the block.
	if code, _ := call(t, e, tid, http.MethodPut, "/v1/me/hours/minutes", a, tabMinutes(at("2026-10-05", 9, 0), 21, "t:task-y")); code != http.StatusOK {
		t.Fatal("minutes")
	}
	if code, out := putEntries(t, e, tid, a, map[string]any{"entries": []any{
		entry("2026-10-05", "t:task-y", 21, "approved"),
		map[string]any{"day": "2026-10-05", "target": "ws", "minutes": 30, "state": "approved", "note": "call"},
	}}); code != http.StatusOK {
		t.Fatalf("approve: %d %v", code, out)
	}
	got := spansOf(t, e, tid, a, "2026-10-05")
	if len(got) != 2 || got[0] != "t:task-y 09:00-09:21 activity" || got[1] != "ch:general 23:30-00:00 timer" {
		t.Fatalf("after the approval: %v", got)
	}
	if r := hoursRow(t, myHours(t, e, tid, a, "2026-10-05"), "2026-10-05", "ws"); r == nil || r["minutes"] != float64(30) {
		t.Fatalf("a typed row without times: %v", r)
	}

	// A timer over the approved block, on another target: refused, nothing written.
	code, out := postTimer(t, e, tid, a, timerBody("t:task-z", at("2026-10-05", 9, 10), at("2026-10-05", 9, 40)))
	if code != http.StatusConflict || out["error"] != "overlap_in_workspace" {
		t.Fatalf("overlap: %d %v", code, out)
	}
	if r := hoursRow(t, myHours(t, e, tid, a, "2026-10-05"), "2026-10-05", "t:task-z"); r != nil {
		t.Fatalf("a refused timer wrote %v", r)
	}
	// The same times for another member are theirs to keep.
	if code, out := postTimer(t, e, tid, b, timerBody("t:task-z", at("2026-10-05", 9, 10), at("2026-10-05", 9, 40))); code != http.StatusOK {
		t.Fatalf("b's timer: %d %v", code, out)
	}
	if got := spansOf(t, e, tid, b, "2026-10-05"); len(got) != 1 || got[0] != "t:task-z 09:10-09:40 timer" {
		t.Fatalf("b's spans: %v", got)
	}
}

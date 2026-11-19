package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 107 T007 and T089, owner Q32 = B (v2.12, msg 2cbfb662, section 23.9):
// at the freeze the sweep approves nothing. A member's open (untapped)
// suggestion, here 21 tab minutes, writes no entry; the frozen period row
// counts only approved entries, so it is 0, and the raw minutes are still
// pruned. A member with nothing gets a 0 row. The clock is hoursNow
// (hours_me_test.go): the week of Mon 09-28 is due. RED CONTROL (master
// before T089): the sweep wrote the 21 minutes as an approved entry.
func TestHoursSweepApprovesNothing(t *testing.T) {
	ctx := context.Background()
	e, tid := hoursEnv(t)
	a := seat(t, e, tid, rbac.Developer)
	idle := seat(t, e, tid, rbac.Developer)
	h := hoursStore(e)
	tue := time.Date(2026, 9, 29, 9, 0, 0, 0, time.UTC)
	var ms []store.HoursMinute
	for i := 0; i < 21; i++ {
		ms = append(ms, store.HoursMinute{At: tue.Add(time.Duration(i) * time.Minute), Target: "t:task-a",
			Src: store.HoursSrcTab, TZ: "UTC"})
	}
	if err := h.UpsertHoursMinutes(ctx, tid, a, ms); err != nil {
		t.Fatal(err)
	}

	r, err := e.srv.SweepHours(ctx, tid)
	if err != nil || r.Pruned != 21 {
		t.Fatalf("sweep = %+v %v, want the 21 minutes pruned", r, err)
	}
	es, err := h.HoursEntries(ctx, tid, a, hoursPrevWeek, "2026-10-04")
	if err != nil || len(es) != 0 {
		t.Fatalf("a's entries = %+v %v, want none: the freeze approves nothing (Q32 = B)", es, err)
	}
	rows, err := h.HoursPeriods(ctx, tid, "", hoursPrevWeek, hoursPrevWeek)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]int{a: 0, idle: 0}
	got := map[string]int{}
	for _, p := range rows {
		if p.State != store.HoursFrozen || p.End != "2026-10-04" {
			t.Fatalf("row = %+v", p)
		}
		got[p.Member] = p.Minutes
	}
	for id, n := range want {
		if m, ok := got[id]; !ok || m != n {
			t.Fatalf("rows = %v, want %v", got, want)
		}
	}
	left, err := h.HoursMinutes(ctx, tid, a, tue.AddDate(0, 0, -1), hoursNow)
	if err != nil || len(left) != 0 {
		t.Fatalf("minutes left = %v %v", left, err)
	}
	// The member's page shows the period frozen at 0 and no approved row.
	got2 := myHours(t, e, tid, a, hoursPrevWeek)
	if row := hoursRow(t, got2, "2026-09-29", "t:task-a"); row != nil && row["state"] == store.HoursApproved {
		t.Fatalf("page row approved without a tap: %v", row)
	}
	if per := got2["period"].(map[string]any); per["state"] != store.HoursFrozen || per["minutes"] != float64(0) {
		t.Fatalf("page period: %v", per)
	}
}

package hub_test

import (
	"context"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 107 T007, owner Q2 = B: at the freeze the hub's sweep turns the open
// suggestions into approved entries (the same suggestions GET /v1/me/hours
// shows), then the period row holds them and the raw minutes are pruned. A
// member with nothing gets a 0 row. The clock is hoursNow (hours_me_test.go):
// the week of Mon 09-28 is due.
func TestHoursSweepAutoApprovesOpenSuggestions(t *testing.T) {
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
	if err != nil || len(es) != 1 {
		t.Fatalf("a's entries = %v %v, want the one auto-approved row", es, err)
	}
	if x := es[0]; x.Day != "2026-09-29" || x.Target != "t:task-a" || x.State != store.HoursApproved ||
		x.Minutes != 21 || x.SuggestedMinutes != 21 || x.UpdatedBy != store.HoursSweepBy {
		t.Fatalf("auto-approved entry = %+v", x)
	}
	rows, err := h.HoursPeriods(ctx, tid, "", hoursPrevWeek, hoursPrevWeek)
	if err != nil {
		t.Fatal(err)
	}
	want := map[string]int{a: 21, idle: 0}
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
	// The member's page shows the row approved and the period frozen.
	got2 := myHours(t, e, tid, a, hoursPrevWeek)
	if row := hoursRow(t, got2, "2026-09-29", "t:task-a"); row == nil || row["state"] != store.HoursApproved {
		t.Fatalf("page row: %v", row)
	}
	if per := got2["period"].(map[string]any); per["state"] != store.HoursFrozen || per["minutes"] != float64(21) {
		t.Fatalf("page period: %v", per)
	}
}

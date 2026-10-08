package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 107 T006: the member routes /v1/me/hours*. Memory, and Postgres
// under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).
//
// The hub clock is Wednesday 2026-10-07 12:00 UTC (hours.tz UTC, a week with
// grace 2): the week of Mon 09-28 froze at 00:00 today by the clock, the week
// of Mon 10-05 is open.

var hoursNow = time.Date(2026, 10, 7, 12, 0, 0, 0, time.UTC)

const (
	hoursPrevWeek = "2026-09-28"
	hoursThisWeek = "2026-10-05"
)

func hoursEnv(t *testing.T) (*env, string) {
	t.Helper()
	e := rbacEnv(t, func(o *hub.Options) { o.Now = func() time.Time { return hoursNow } })
	tid, _ := e.tenant()
	return e, tid
}

func hoursStore(e *env) store.Hours { return e.st.(store.Hours) }

// tabMinutes is n tab minutes on target from at, as the WUI sends them.
func tabMinutes(at time.Time, n int, target string) map[string]any {
	ms := []map[string]any{}
	for i := 0; i < n; i++ {
		ms = append(ms, map[string]any{"at": at.Add(time.Duration(i) * time.Minute).Format(time.RFC3339), "target": target})
	}
	return map[string]any{"tz": "UTC", "minutes": ms}
}

func myHours(t *testing.T, e *env, tid, as, period string) map[string]any {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/me/hours?period="+period, as, nil)
	if code != http.StatusOK {
		t.Fatalf("GET /v1/me/hours?period=%s as %s: %d %v", period, as, code, out)
	}
	return out
}

// hoursDay is the day d of a GET answer.
func hoursDay(t *testing.T, out map[string]any, d string) map[string]any {
	t.Helper()
	days, _ := out["days"].([]any)
	for _, x := range days {
		if m := x.(map[string]any); m["date"] == d {
			return m
		}
	}
	t.Fatalf("no day %s in %v", d, out)
	return nil
}

// hoursRow is the row of target on day d, nil when none.
func hoursRow(t *testing.T, out map[string]any, d, target string) map[string]any {
	t.Helper()
	rows, _ := hoursDay(t, out, d)["rows"].([]any)
	for _, x := range rows {
		if m := x.(map[string]any); m["target"] == target {
			return m
		}
	}
	return nil
}

func hoursRowCount(t *testing.T, out map[string]any, d string) int {
	t.Helper()
	rows, _ := hoursDay(t, out, d)["rows"].([]any)
	return len(rows)
}

func putEntries(t *testing.T, e *env, tid, as string, body map[string]any) (int, map[string]any) {
	t.Helper()
	return call(t, e, tid, http.MethodPut, "/v1/me/hours", as, body)
}

func entry(day, target string, minutes int, state string) map[string]any {
	return map[string]any{"day": day, "target": target, "minutes": minutes, "state": state}
}

func TestMyHoursMinutesSuggestPrivate(t *testing.T) {
	e, tid := hoursEnv(t)
	a := seat(t, e, tid, rbac.Developer)
	b := seat(t, e, tid, rbac.Developer)
	mon := time.Date(2026, 10, 5, 9, 0, 0, 0, time.UTC)

	code, out := call(t, e, tid, http.MethodPut, "/v1/me/hours/minutes", a, tabMinutes(mon, 21, "t:task-a"))
	if code != http.StatusOK || out["stored"] != float64(21) {
		t.Fatalf("put minutes: %d %v", code, out)
	}
	got := myHours(t, e, tid, a, "2026-10-05")
	per := got["period"].(map[string]any)
	if per["start"] != hoursThisWeek || per["end"] != "2026-10-11" || per["state"] != "open" || got["today"] != "2026-10-07" {
		t.Fatalf("period: %v today %v", per, got["today"])
	}
	row := hoursRow(t, got, "2026-10-05", "t:task-a")
	if row == nil || row["state"] != "suggested" || row["minutes"] != float64(21) {
		t.Fatalf("a's suggestion: %v", row)
	}
	if blocks, _ := row["blocks"].([]any); len(blocks) != 1 {
		t.Fatalf("a's blocks: %v", row)
	}
	if d := hoursDay(t, got, "2026-10-05"); d["closed"] != true || d["open"] != float64(1) || d["suggested_minutes"] != float64(21) {
		t.Fatalf("monday: %v", d)
	}
	if d := hoursDay(t, got, "2026-10-07"); d["today"] != true || d["closed"] != false {
		t.Fatalf("today: %v", d)
	}

	// A second member never sees the first's minutes.
	if n := hoursRowCount(t, myHours(t, e, tid, b, "2026-10-05"), "2026-10-05"); n != 0 {
		t.Fatalf("b sees %d rows of a's minutes", n)
	}
	// b's own minutes on the same wall-clock minutes stay b's.
	if code, out := call(t, e, tid, http.MethodPut, "/v1/me/hours/minutes", b, tabMinutes(mon, 8, "ch:general")); code != http.StatusOK {
		t.Fatalf("b put: %d %v", code, out)
	}
	got = myHours(t, e, tid, a, "2026-10-05")
	if hoursRowCount(t, got, "2026-10-05") != 1 || hoursRow(t, got, "2026-10-05", "ch:general") != nil {
		t.Fatalf("a sees b's minutes: %v", hoursDay(t, got, "2026-10-05"))
	}
	if hoursRow(t, myHours(t, e, tid, b, "2026-10-05"), "2026-10-05", "ch:general")["minutes"] != float64(8) {
		t.Fatal("b's own suggestion missing")
	}
	// No session, no hours.
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/me/hours", "", nil); code < 400 {
		t.Fatalf("anonymous GET: %d", code)
	}
}

func TestMyHoursMinutesRefusals(t *testing.T) {
	e, tid := hoursEnv(t)
	a := seat(t, e, tid, rbac.Developer)
	mon := time.Date(2026, 10, 5, 9, 0, 0, 0, time.UTC)
	for name, body := range map[string]map[string]any{
		"61 rows": tabMinutes(mon, 61, "t:x"),
		"no rows": {"tz": "UTC", "minutes": []any{}},
		"bad tz":  {"tz": "Mars/Base", "minutes": tabMinutes(mon, 1, "t:x")["minutes"]},
		"future":  tabMinutes(hoursNow.Add(10*time.Minute), 1, "t:x"),
		"old":     tabMinutes(hoursNow.AddDate(0, 0, -46), 1, "t:x"),
		"target":  tabMinutes(mon, 1, "cal:x"),
		"unknown": {"tz": "UTC", "minutes": tabMinutes(mon, 1, "t:x")["minutes"], "src": "post"},
	} {
		if code, out := call(t, e, tid, http.MethodPut, "/v1/me/hours/minutes", a, body); code != http.StatusBadRequest {
			t.Errorf("%s: %d %v", name, code, out)
		}
	}
	if code, out := call(t, e, tid, http.MethodPut, "/v1/me/hours/minutes", a, tabMinutes(mon, 60, "t:x")); code != http.StatusOK {
		t.Fatalf("CONTROL 60 rows: %d %v", code, out)
	}
}

// A frozen day is 409 period_frozen, with and without a sweep row.
func TestMyHoursFrozen(t *testing.T) {
	e, tid := hoursEnv(t)
	a := seat(t, e, tid, rbac.Developer)
	ctx := context.Background()
	wed := time.Date(2026, 9, 30, 9, 0, 0, 0, time.UTC)
	// Minutes the hub recorded before the freeze.
	if err := hoursStore(e).UpsertHoursMinutes(ctx, tid, a, []store.HoursMinute{
		{At: wed, Target: "t:old", Src: store.HoursSrcPost, TZ: "UTC"}}); err != nil {
		t.Fatal(err)
	}

	// Without a row: frozen by the clock.
	if code, out := call(t, e, tid, http.MethodPut, "/v1/me/hours/minutes", a, tabMinutes(wed, 1, "t:x")); code != http.StatusConflict || out["error"] != "period_frozen" {
		t.Fatalf("minutes, no row: %d %v", code, out)
	}
	body := map[string]any{"entries": []any{entry("2026-09-30", "t:old", 30, "approved")}}
	if code, out := putEntries(t, e, tid, a, body); code != http.StatusConflict || out["error"] != "period_frozen" {
		t.Fatalf("entries, no row: %d %v", code, out)
	}
	got := myHours(t, e, tid, a, "2026-09-30")
	if got["period"].(map[string]any)["state"] != "frozen" || hoursDay(t, got, "2026-09-30")["frozen"] != true ||
		hoursRowCount(t, got, "2026-09-30") != 0 {
		t.Fatalf("frozen week shows: %v", got)
	}

	// With a sweep row on the open week.
	if _, err := hoursStore(e).CreateHoursPeriod(ctx, tid, store.HoursPeriod{Member: a, Start: hoursThisWeek, End: "2026-10-11",
		State: store.HoursFrozen, DecidedBy: "sweep", DecidedAt: hoursNow}); err != nil {
		t.Fatal(err)
	}
	mon := time.Date(2026, 10, 5, 9, 0, 0, 0, time.UTC)
	if code, out := call(t, e, tid, http.MethodPut, "/v1/me/hours/minutes", a, tabMinutes(mon, 1, "t:x")); code != http.StatusConflict || out["error"] != "period_frozen" {
		t.Fatalf("minutes, row: %d %v", code, out)
	}
	if code, out := putEntries(t, e, tid, a, map[string]any{"entries": []any{entry("2026-10-05", "t:x", 30, "approved")}}); code != http.StatusConflict || out["error"] != "period_frozen" {
		t.Fatalf("entries, row: %d %v", code, out)
	}
	// CONTROL: another member of the workspace has no row and writes.
	b := seat(t, e, tid, rbac.Developer)
	if code, out := putEntries(t, e, tid, b, map[string]any{"entries": []any{entry("2026-10-05", "t:x", 30, "approved")}}); code != http.StatusOK {
		t.Fatalf("CONTROL b: %d %v", code, out)
	}
}

func TestMyHoursApproveEditRejectAddDelta(t *testing.T) {
	e, tid := hoursEnv(t)
	a := seat(t, e, tid, rbac.Developer)
	mon := time.Date(2026, 10, 5, 9, 0, 0, 0, time.UTC)
	call(t, e, tid, http.MethodPut, "/v1/me/hours/minutes", a, tabMinutes(mon, 20, "t:task-a"))
	call(t, e, tid, http.MethodPut, "/v1/me/hours/minutes", a, tabMinutes(mon.Add(3*time.Hour), 15, "ch:general"))

	// Approve one row, reject the other, add a third.
	code, out := putEntries(t, e, tid, a, map[string]any{"entries": []any{
		entry("2026-10-05", "t:task-a", 20, "approved"),
		entry("2026-10-05", "ch:general", 0, "rejected"),
		map[string]any{"day": "2026-10-05", "target": "ws", "minutes": 30, "state": "approved", "note": "call"},
	}})
	if code != http.StatusOK {
		t.Fatalf("approve: %d %v", code, out)
	}
	if r := hoursRow(t, out, "2026-10-05", "t:task-a"); r["state"] != "approved" || r["minutes"] != float64(20) || r["suggested_minutes"] != float64(20) {
		t.Fatalf("approved row: %v", r)
	}
	if r := hoursRow(t, out, "2026-10-05", "ch:general"); r["state"] != "rejected" || r["suggested_minutes"] != float64(15) {
		t.Fatalf("rejected row: %v", r)
	}
	if r := hoursRow(t, out, "2026-10-05", "ws"); r["minutes"] != float64(30) || r["suggested_minutes"] != float64(0) || r["note"] != "call" {
		t.Fatalf("added row: %v", r)
	}
	if d := hoursDay(t, out, "2026-10-05"); d["approved_minutes"] != float64(50) || d["open"] != float64(0) {
		t.Fatalf("day after approve: %v", d)
	}

	// Later activity is a delta; an approved number never changes silently.
	call(t, e, tid, http.MethodPut, "/v1/me/hours/minutes", a, tabMinutes(mon.Add(20*time.Minute), 10, "t:task-a"))
	got := myHours(t, e, tid, a, "2026-10-05")
	if r := hoursRow(t, got, "2026-10-05", "t:task-a"); r["minutes"] != float64(20) || r["delta"] != float64(10) {
		t.Fatalf("delta: %v", r)
	}
	// One-tap accept: minutes + delta.
	code, out = putEntries(t, e, tid, a, map[string]any{"entries": []any{entry("2026-10-05", "t:task-a", 30, "approved")}})
	if r := hoursRow(t, out, "2026-10-05", "t:task-a"); code != http.StatusOK || r["minutes"] != float64(30) || r["delta"] != nil {
		t.Fatalf("accept delta: %d %v", code, r)
	}
	// Take the added row back.
	code, out = putEntries(t, e, tid, a, map[string]any{"remove": []any{map[string]any{"day": "2026-10-05", "target": "ws"}}})
	if code != http.StatusOK || hoursRow(t, out, "2026-10-05", "ws") != nil {
		t.Fatalf("remove: %d %v", code, out)
	}

	// Refusals: a day after today, the day cap, nothing to write.
	if code, out := putEntries(t, e, tid, a, map[string]any{"entries": []any{entry("2026-10-08", "t:x", 10, "approved")}}); code != http.StatusBadRequest || out["error"] != "bad_day" {
		t.Fatalf("future day: %d %v", code, out)
	}
	if code, out := putEntries(t, e, tid, a, map[string]any{"entries": []any{entry("2026-10-06", "t:x", 1000, "approved"), entry("2026-10-06", "t:y", 500, "approved")}}); code != http.StatusBadRequest || out["error"] != "day_cap" {
		t.Fatalf("day cap: %d %v", code, out)
	}
	if code, _ := putEntries(t, e, tid, a, map[string]any{}); code != http.StatusBadRequest {
		t.Fatalf("empty batch: %d", code)
	}
	// A rejected batch writes nothing: the frozen day refuses the open one too.
	code, _ = putEntries(t, e, tid, a, map[string]any{"entries": []any{entry("2026-10-06", "t:z", 10, "approved"), entry("2026-09-30", "t:z", 10, "approved")}})
	if code != http.StatusConflict || hoursRow(t, myHours(t, e, tid, a, "2026-10-06"), "2026-10-06", "t:z") != nil {
		t.Fatalf("mixed batch: %d", code)
	}
}

// A returned period: no suggestions, editable, Resubmit -> frozen.
func TestMyHoursReturnedResubmit(t *testing.T) {
	e, tid := hoursEnv(t)
	a := seat(t, e, tid, rbac.Developer)
	ctx := context.Background()
	hs := hoursStore(e)
	if err := hs.UpsertHoursMinutes(ctx, tid, a, []store.HoursMinute{
		{At: time.Date(2026, 9, 29, 9, 0, 0, 0, time.UTC), Target: "t:old", Src: store.HoursSrcPost, TZ: "UTC"}}); err != nil {
		t.Fatal(err)
	}
	if _, err := hs.CreateHoursPeriod(ctx, tid, store.HoursPeriod{Member: a, Start: hoursPrevWeek, End: "2026-10-04",
		State: store.HoursFrozen, DecidedBy: "sweep", DecidedAt: hoursNow}); err != nil {
		t.Fatal(err)
	}
	// Resubmit of a frozen period is refused.
	if code, out := putEntries(t, e, tid, a, map[string]any{"resubmit": "2026-09-29"}); code != http.StatusConflict || out["error"] != "period_state" {
		t.Fatalf("resubmit frozen: %d %v", code, out)
	}
	if _, err := hs.SetHoursPeriodState(ctx, tid, a, hoursPrevWeek, store.HoursPeriodChange{State: store.HoursReturned,
		Note: "Tuesday is missing", By: "HUM-owner", At: hoursNow}); err != nil {
		t.Fatal(err)
	}
	got := myHours(t, e, tid, a, "2026-09-29")
	per := got["period"].(map[string]any)
	if per["state"] != "returned" || per["note"] != "Tuesday is missing" || hoursDay(t, got, "2026-09-29")["frozen"] != false {
		t.Fatalf("returned period: %v", got)
	}
	if n := hoursRowCount(t, got, "2026-09-29"); n != 0 {
		t.Fatalf("a returned period shows %d suggested rows", n)
	}
	code, out := putEntries(t, e, tid, a, map[string]any{"entries": []any{entry("2026-09-29", "t:old", 90, "approved")}, "resubmit": "2026-09-29"})
	if code != http.StatusOK {
		t.Fatalf("fix + resubmit: %d %v", code, out)
	}
	if per := out["period"].(map[string]any); per["state"] != "frozen" || per["minutes"] != float64(90) {
		t.Fatalf("after resubmit: %v", per)
	}
	if code, out := putEntries(t, e, tid, a, map[string]any{"entries": []any{entry("2026-09-29", "t:old", 60, "approved")}}); code != http.StatusConflict || out["error"] != "period_frozen" {
		t.Fatalf("edit after resubmit: %d %v", code, out)
	}
}

// Meetings (spec 1.4, owner Q6 = A): accepted, timed events of kind other.
func TestMyHoursMeetings(t *testing.T) {
	e, tid := hoursEnv(t)
	a := seat(t, e, tid, rbac.Developer)
	b := seat(t, e, tid, rbac.Developer)
	cal := e.st.(store.Calendar)
	ctx := context.Background()
	at := time.Date(2026, 10, 6, 10, 0, 0, 0, time.UTC)
	mk := func(kind string, start time.Time, guests ...string) string {
		t.Helper()
		ev := store.CalendarEvent{Title: kind + " sync", Kind: kind, StartsAt: start, EndsAt: start.Add(time.Hour),
			CreatorType: "human", CreatorID: a}
		for _, g := range guests {
			ev.Guests = append(ev.Guests, store.CalendarGuest{Type: "human", ID: g})
		}
		got, err := cal.CreateCalendarEvent(ctx, tid, ev, hoursNow)
		if err != nil {
			t.Fatal(err)
		}
		return got.ID
	}
	sync := mk("other", at, b)
	mk("deploy", at.Add(3*time.Hour))
	got := myHours(t, e, tid, a, "2026-10-06")
	if r := hoursRow(t, got, "2026-10-06", "cal:"+sync); r == nil || r["minutes"] != float64(60) {
		t.Fatalf("a's meeting: %v", hoursDay(t, got, "2026-10-06"))
	}
	if n := hoursRowCount(t, got, "2026-10-06"); n != 1 {
		t.Fatalf("a deploy window was suggested: %v", hoursDay(t, got, "2026-10-06"))
	}
	// b has not answered: no meeting; after yes, the meeting.
	if n := hoursRowCount(t, myHours(t, e, tid, b, "2026-10-06"), "2026-10-06"); n != 0 {
		t.Fatalf("unanswered guest gets %d rows", n)
	}
	if _, err := e.st.(store.CalendarGuests).RespondCalendarEvent(ctx, tid, b, sync, store.CalendarRSVP{Response: store.CalendarYes}, hoursNow); err != nil {
		t.Fatal(err)
	}
	if r := hoursRow(t, myHours(t, e, tid, b, "2026-10-06"), "2026-10-06", "cal:"+sync); r == nil || r["minutes"] != float64(60) {
		t.Fatalf("b after yes: %v", r)
	}
}

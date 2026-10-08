package hub_test

import (
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Spec 107 Q7 = B (T019): POST /v1/me/hours/timer. The clock and weeks are
// hours_me_test.go's: Wed 2026-10-07 12:00 UTC, the week of 09-28 frozen.

func timerBody(target string, start, end time.Time) map[string]any {
	return map[string]any{"target": target, "start": start.Format(time.RFC3339), "end": end.Format(time.RFC3339)}
}

func postTimer(t *testing.T, e *env, tid, as string, body map[string]any) (int, map[string]any) {
	t.Helper()
	return call(t, e, tid, http.MethodPost, "/v1/me/hours/timer", as, body)
}

func at(day string, hh, mm int) time.Time {
	d, _ := time.Parse("2006-01-02", day)
	return d.Add(time.Duration(hh)*time.Hour + time.Duration(mm)*time.Minute)
}

func TestMyHoursTimerWritesAndAdds(t *testing.T) {
	e, tid := hoursEnv(t)
	a := seat(t, e, tid, rbac.Developer)
	b := seat(t, e, tid, rbac.Developer)

	code, out := postTimer(t, e, tid, a, timerBody("t:task-x", at("2026-10-07", 9, 0), at("2026-10-07", 10, 30)))
	if code != http.StatusOK {
		t.Fatalf("stop: %d %v", code, out)
	}
	if w, _ := out["written"].([]any); len(w) != 1 || w[0].(map[string]any)["minutes"] != float64(90) {
		t.Fatalf("written: %v", out["written"])
	}
	row := hoursRow(t, myHours(t, e, tid, a, "2026-10-07"), "2026-10-07", "t:task-x")
	if row == nil || row["state"] != "approved" || row["minutes"] != float64(90) || row["suggested_minutes"] != float64(0) {
		t.Fatalf("entry: %v", row)
	}
	// A second run on the same target adds to the row.
	if code, out := postTimer(t, e, tid, a, timerBody("t:task-x", at("2026-10-07", 11, 0), at("2026-10-07", 11, 30))); code != http.StatusOK {
		t.Fatalf("second stop: %d %v", code, out)
	}
	if row := hoursRow(t, myHours(t, e, tid, a, "2026-10-07"), "2026-10-07", "t:task-x"); row["minutes"] != float64(120) {
		t.Fatalf("added: %v", row)
	}
	// Over an open suggestion: the suggestion plus the run, approved.
	if code, _ := call(t, e, tid, http.MethodPut, "/v1/me/hours/minutes", a, tabMinutes(at("2026-10-05", 9, 0), 21, "t:task-y")); code != http.StatusOK {
		t.Fatal("minutes")
	}
	if code, out := postTimer(t, e, tid, a, timerBody("t:task-y", at("2026-10-05", 14, 0), at("2026-10-05", 14, 30))); code != http.StatusOK {
		t.Fatalf("over a suggestion: %d %v", code, out)
	}
	row = hoursRow(t, myHours(t, e, tid, a, "2026-10-05"), "2026-10-05", "t:task-y")
	if row["state"] != "approved" || row["minutes"] != float64(51) || row["suggested_minutes"] != float64(21) {
		t.Fatalf("over a suggestion: %v", row)
	}
	// A second member sees none of it.
	for _, d := range []string{"2026-10-05", "2026-10-07"} {
		if n := hoursRowCount(t, myHours(t, e, tid, b, d), d); n != 0 {
			t.Fatalf("b sees %d of a's rows on %s", n, d)
		}
	}
}

// Over midnight: one entry per local day.
func TestMyHoursTimerSplitsAtMidnight(t *testing.T) {
	e, tid := hoursEnv(t)
	a := seat(t, e, tid, rbac.Developer)
	code, out := postTimer(t, e, tid, a, timerBody("ch:general", at("2026-10-05", 23, 30), at("2026-10-06", 0, 45)))
	if code != http.StatusOK {
		t.Fatalf("stop: %d %v", code, out)
	}
	got := myHours(t, e, tid, a, "2026-10-05")
	if m := hoursRow(t, got, "2026-10-05", "ch:general")["minutes"]; m != float64(30) {
		t.Fatalf("monday: %v", m)
	}
	if m := hoursRow(t, got, "2026-10-06", "ch:general")["minutes"]; m != float64(45) {
		t.Fatalf("tuesday: %v", m)
	}
}

// A frozen day is 409 period_frozen and nothing of the interval is written.
func TestMyHoursTimerFrozen(t *testing.T) {
	e, tid := hoursEnv(t)
	a := seat(t, e, tid, rbac.Developer)
	code, out := postTimer(t, e, tid, a, timerBody("t:x", at("2026-09-30", 10, 0), at("2026-09-30", 11, 0)))
	if code != http.StatusConflict || out["error"] != "period_frozen" {
		t.Fatalf("frozen day: %d %v", code, out)
	}
	// Sunday 10-04 (frozen) into Monday 10-05 (open): all or none.
	code, out = postTimer(t, e, tid, a, timerBody("t:x", at("2026-10-04", 23, 0), at("2026-10-05", 1, 0)))
	if code != http.StatusConflict || out["error"] != "period_frozen" {
		t.Fatalf("across the freeze: %d %v", code, out)
	}
	if n := hoursRowCount(t, myHours(t, e, tid, a, "2026-10-05"), "2026-10-05"); n != 0 {
		t.Fatalf("monday got %d rows from a refused run", n)
	}
}

// The 1440-minute day cap and the refusals of a bad body.
func TestMyHoursTimerRefusals(t *testing.T) {
	e, tid := hoursEnv(t)
	a := seat(t, e, tid, rbac.Developer)
	if code, out := putEntries(t, e, tid, a, map[string]any{"entries": []any{entry("2026-10-06", "t:a", 1400, "approved")}}); code != http.StatusOK {
		t.Fatalf("seed: %d %v", code, out)
	}
	code, out := postTimer(t, e, tid, a, timerBody("t:b", at("2026-10-06", 10, 0), at("2026-10-06", 11, 0)))
	if code != http.StatusBadRequest || out["error"] != "day_cap" {
		t.Fatalf("over 1440: %d %v", code, out)
	}
	if hoursRow(t, myHours(t, e, tid, a, "2026-10-06"), "2026-10-06", "t:b") != nil {
		t.Fatal("a refused run wrote a row")
	}
	for name, body := range map[string]map[string]any{
		"over 24 h": timerBody("t:b", at("2026-10-05", 9, 0), at("2026-10-06", 9, 1)),
		"future":    timerBody("t:b", at("2026-10-07", 11, 0), at("2026-10-07", 13, 0)),
		"backwards": timerBody("t:b", at("2026-10-07", 11, 0), at("2026-10-07", 10, 0)),
		"short":     timerBody("t:b", at("2026-10-07", 11, 0), at("2026-10-07", 11, 0).Add(20*time.Second)),
		"no target": timerBody("", at("2026-10-07", 10, 0), at("2026-10-07", 11, 0)),
		"target":    timerBody("bogus", at("2026-10-07", 10, 0), at("2026-10-07", 11, 0)),
	} {
		if code, out := postTimer(t, e, tid, a, body); code != http.StatusBadRequest {
			t.Errorf("%s: %d %v", name, code, out)
		}
	}
	if code, out := postTimer(t, e, tid, a, timerBody("t:b", at("2026-10-06", 10, 0), at("2026-10-06", 10, 40))); code != http.StatusOK {
		t.Fatalf("CONTROL under the cap: %d %v", code, out)
	}
	if code, _ := postTimer(t, e, tid, "", timerBody("t:b", at("2026-10-07", 10, 0), at("2026-10-07", 11, 0))); code < 400 {
		t.Fatalf("anonymous: %d", code)
	}
}

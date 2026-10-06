package hub_test

import (
	"net/http"
	"net/url"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// specs/097 T006: recurrence on the wire (spec 4.4). AC-04 end to end
// through the routes: a weekly series in Europe/Helsinki across the October
// daylight-saving change, edit "this", delete "following", edit "all"; an
// occurrence answers its id, recurring_event_id, original_start and rrule;
// ?scope= and rrule outside the subset are 400; more than 2000 occurrences
// in one range is 400 bad_range.

const calAutumnQuery = "/v1/calendar/events?start=2026-10-01T00:00:00Z&end=2026-12-01T00:00:00Z"

// calHelsinkiTimes lists an answer's events as "Oct 19 09:00 title" in
// Helsinki.
func calHelsinkiTimes(t *testing.T, out map[string]any) string {
	t.Helper()
	loc, err := time.LoadLocation("Europe/Helsinki")
	if err != nil {
		t.Fatal(err)
	}
	var got []string
	list, _ := out["events"].([]any)
	for _, x := range list {
		ev := x.(map[string]any)
		at, err := time.Parse(time.RFC3339, ev["starts_at"].(string))
		if err != nil {
			t.Fatalf("starts_at: %v", ev)
		}
		got = append(got, at.In(loc).Format("Jan 2 15:04 ")+ev["title"].(string))
	}
	return strings.Join(got, ", ")
}

func calEvents(t *testing.T, out map[string]any) []map[string]any {
	t.Helper()
	var evs []map[string]any
	list, _ := out["events"].([]any)
	for _, x := range list {
		evs = append(evs, x.(map[string]any))
	}
	return evs
}

// AC-04 over the routes.
func TestCalendarSeriesAC04Routes(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	s := calCreate(t, e, tid, dev, map[string]any{"title": "standup", "starts_at": "2026-10-19T06:00:00Z",
		"ends_at": "2026-10-19T06:30:00Z", "time_zone": "Europe/Helsinki", "rrule": "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6"})
	sid := s["id"].(string)
	if s["rrule"] != "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6" || s["recurring_event_id"] != "" {
		t.Fatalf("the series answer: %v", s)
	}
	_, out := call(t, e, tid, http.MethodGet, calAutumnQuery, dev, nil)
	want := "Oct 19 09:00 standup, Oct 21 09:00 standup, Oct 26 09:00 standup, Oct 28 09:00 standup, " +
		"Nov 2 09:00 standup, Nov 4 09:00 standup"
	if got := calHelsinkiTimes(t, out); got != want {
		t.Fatalf("six at 09:00 local:\n got %s\nwant %s", got, want)
	}
	evs := calEvents(t, out)
	if o := evs[2]; o["id"] != sid+"_20261026T070000Z" || o["recurring_event_id"] != sid ||
		o["original_start"] != "2026-10-26T07:00:00Z" || o["rrule"] != s["rrule"] {
		t.Fatalf("an occurrence on the wire: %v", o)
	}

	// edit "this" moves one (If-Match is the occurrence's updated_at)
	path := "/v1/calendar/events/" + evs[1]["id"].(string) + "?scope=this"
	code, out := calendarIfMatch(t, e, tid, http.MethodPatch, path, dev, `"`+evs[1]["updated_at"].(string)+`"`,
		map[string]any{"starts_at": "2026-10-21T08:00:00Z", "ends_at": "2026-10-21T08:30:00Z"})
	if ev := calEvent(t, out); code != http.StatusOK || ev["id"] != evs[1]["id"] || ev["starts_at"] != "2026-10-21T08:00:00Z" {
		t.Fatalf("edit this: %d %v", code, out)
	}
	if code, out := calendarIfMatch(t, e, tid, http.MethodPatch, path, dev, `"`+evs[1]["updated_at"].(string)+`"`,
		map[string]any{"title": "late"}); code != http.StatusConflict || calEvent(t, out)["starts_at"] != "2026-10-21T08:00:00Z" {
		t.Fatalf("a stale If-Match on the occurrence: %d %v", code, out)
	}
	// delete "following" from the 4th leaves three
	code, out = call(t, e, tid, http.MethodDelete, "/v1/calendar/events/"+evs[3]["id"].(string)+"?scope=following", dev, nil)
	if code != http.StatusOK {
		t.Fatalf("delete following: %d %v", code, out)
	}
	if _, out := call(t, e, tid, http.MethodGet, calAutumnQuery, dev, nil); calHelsinkiTimes(t, out) !=
		"Oct 19 09:00 standup, Oct 21 11:00 standup, Oct 26 09:00 standup" {
		t.Fatalf("after delete following: %s", calHelsinkiTimes(t, out))
	}
	// edit "all" from an occurrence: an hour later; the moved one stays moved
	code, out = call(t, e, tid, http.MethodPatch, "/v1/calendar/events/"+evs[2]["id"].(string)+"?scope=all", dev,
		map[string]any{"starts_at": "2026-10-26T08:00:00Z", "ends_at": "2026-10-26T08:30:00Z", "title": "sync"})
	if code != http.StatusOK || calEvent(t, out)["id"] != sid {
		t.Fatalf("edit all answers the series: %d %v", code, out)
	}
	if _, out := call(t, e, tid, http.MethodGet, calAutumnQuery, dev, nil); calHelsinkiTimes(t, out) !=
		"Oct 19 10:00 sync, Oct 21 11:00 sync, Oct 26 10:00 sync" {
		t.Fatalf("after edit all: %s", calHelsinkiTimes(t, out))
	}
	// the year strip counts the occurrences
	_, out = call(t, e, tid, http.MethodGet, "/v1/calendar/marks?start_year=2026&end_year=2026", dev, nil)
	if days, _ := out["days"].([]any); len(days) != 3 {
		t.Fatalf("marks of three occurrences: %v", out)
	}
}

func TestCalendarSeriesRefusals(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	for _, rule := range []string{"FREQ=HOURLY", "FREQ=WEEKLY;BYSETPOS=1", "FREQ=DAILY;COUNT=3;UNTIL=20261231"} {
		code, out := call(t, e, tid, http.MethodPost, "/v1/calendar/events", dev, calBody("x", map[string]any{"rrule": rule}))
		if code != http.StatusBadRequest || out["error"] != "bad_event" {
			t.Fatalf("rrule %q: %d %v", rule, code, out)
		}
	}
	s := calCreate(t, e, tid, dev, calBody("daily", map[string]any{"rrule": "FREQ=DAILY"}))
	sid := s["id"].(string)
	for _, path := range []string{"/v1/calendar/events/" + sid + "?scope=this", "/v1/calendar/events/" + sid + "?scope=nope"} {
		if code, out := call(t, e, tid, http.MethodPatch, path, dev, map[string]any{"title": "y"}); code != http.StatusBadRequest {
			t.Fatalf("PATCH %s: %d %v", path, code, out)
		}
		if code, out := call(t, e, tid, http.MethodDelete, path, dev, nil); code != http.StatusBadRequest {
			t.Fatalf("DELETE %s: %d %v", path, code, out)
		}
	}
	// scope on a single event is ignored
	one := calCreate(t, e, tid, dev, calBody("one", nil))
	if code, out := call(t, e, tid, http.MethodPatch, "/v1/calendar/events/"+one["id"].(string)+"?scope=following", dev,
		map[string]any{"title": "one!"}); code != http.StatusOK {
		t.Fatalf("scope on a single event: %d %v", code, out)
	}
	// five more daily series: 6 x 400 days is past the 2000-occurrence cap
	for i := 0; i < 5; i++ {
		calCreate(t, e, tid, dev, calBody("daily", map[string]any{"rrule": "FREQ=DAILY"}))
	}
	q := "/v1/calendar/events?start=" + url.QueryEscape("2026-10-01T00:00:00Z") + "&end=" + url.QueryEscape("2027-11-01T00:00:00Z")
	if code, out := call(t, e, tid, http.MethodGet, q, dev, nil); code != http.StatusBadRequest || out["error"] != "bad_range" {
		t.Fatalf("more than 2000 occurrences: %d %v", code, out)
	}
	if code, _ := call(t, e, tid, http.MethodGet, calWeekQuery, dev, nil); code != http.StatusOK {
		t.Fatalf("CONTROL a week: %d", code)
	}
}

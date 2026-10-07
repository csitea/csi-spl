package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// specs/097 T007: guests and RSVP on the wire (spec 4.5). AC-05 through the
// routes: a guest answers maybe, the owner sees it with no my_response of
// their own, a non-guest's rsvp is 403 not_a_guest, a private event is
// readable by its guests and nobody else. A guest outside the workspace is
// 400; guests are kept in mentions, and a dropped guest leaves both; c-394's
// 089 body still answers guests [] and my_response "".

func calGuest(typ, id string) map[string]any { return map[string]any{"type": typ, "id": id} }

// calGuestAnswers is an event's guests as "id=response".
func calGuestAnswers(ev map[string]any) map[string]string {
	out := map[string]string{}
	list, _ := ev["guests"].([]any)
	for _, x := range list {
		g := x.(map[string]any)
		out[g["id"].(string)] = g["response"].(string)
	}
	return out
}

func calHas(list any, id string) bool {
	xs, _ := list.([]any)
	for _, x := range xs {
		if x == id {
			return true
		}
	}
	return false
}

func TestCalendarGuestsAC05Routes(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev, mate, other := seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
	if err := e.st.SetRoster(context.Background(), tid, "box-a", []string{"c-042"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	// c-394's 089 body: the new fields at their defaults.
	if ev := calCreate(t, e, tid, dev, calBody("plain", nil)); len(ev["guests"].([]any)) != 0 || ev["my_response"] != "" {
		t.Fatalf("089 body: %v", ev)
	}
	// A guest outside the workspace is refused; the owner is never listed.
	for _, g := range []map[string]any{calGuest("human", "HUM-nobody"), calGuest("agent", "c-999"), calGuest("robot", mate)} {
		code, out := call(t, e, tid, http.MethodPost, "/v1/calendar/events", dev, calBody("x", map[string]any{"guests": []any{g}}))
		if code != http.StatusBadRequest || out["error"] != "bad_event" {
			t.Fatalf("guest %v: %d %v", g, code, out)
		}
	}
	ev := calCreate(t, e, tid, dev, calBody("1:1", map[string]any{"audience": "private", "notify_guests": false,
		"guests": []any{calGuest("human", mate), calGuest("agent", "c-042@box-a"), calGuest("human", dev)}}))
	path := "/v1/calendar/events/" + ev["id"].(string)
	if a := calGuestAnswers(ev); len(a) != 2 || a[mate] != "needs_action" || a["c-042@box-a"] != "needs_action" ||
		!calHas(ev["mentions"], mate) || !calHas(ev["mentions"], "c-042@box-a") || ev["my_response"] != "" {
		t.Fatalf("the create: %v", ev)
	}
	// A private event: readable by its guest, not by a member who is not one.
	if _, out := call(t, e, tid, http.MethodGet, calWeekQuery, mate, nil); calTitles(out, "events") != "1:1,plain" &&
		calTitles(out, "events") != "plain,1:1" {
		t.Fatalf("the guest reads: %v", out)
	}
	if _, out := call(t, e, tid, http.MethodGet, calWeekQuery, other, nil); calTitles(out, "events") != "plain" {
		t.Fatalf("a non-guest reads: %v", out)
	}
	if code, out := call(t, e, tid, http.MethodPost, path+"/rsvp", other, map[string]any{"response": "yes"}); code != http.StatusNotFound {
		t.Fatalf("a non-guest answers a private event: %d %v", code, out)
	}
	// The guest answers maybe; the owner sees it.
	code, out := call(t, e, tid, http.MethodPost, path+"/rsvp", mate, map[string]any{"response": "maybe", "comment": "if I can"})
	if got := calEvent(t, out); code != http.StatusOK || got["my_response"] != "maybe" || calGuestAnswers(got)[mate] != "maybe" {
		t.Fatalf("the guest answers maybe: %d %v", code, out)
	}
	_, out = call(t, e, tid, http.MethodGet, calWeekQuery, dev, nil)
	for _, x := range calEvents(t, out) {
		if x["title"] == "1:1" && (calGuestAnswers(x)[mate] != "maybe" || x["my_response"] != "") {
			t.Fatalf("the owner sees the answer: %v", x)
		}
	}
	// The owner and, on a public event, a non-guest are 403 not_a_guest.
	pub := calCreate(t, e, tid, dev, calBody("all hands", map[string]any{"guests": []any{calGuest("human", mate)}}))
	for _, who := range []string{dev, other} {
		code, out := call(t, e, tid, http.MethodPost, "/v1/calendar/events/"+pub["id"].(string)+"/rsvp", who, map[string]any{"response": "yes"})
		if code != http.StatusForbidden || out["error"] != "not_a_guest" {
			t.Fatalf("%s answers as a non-guest: %d %v", who, code, out)
		}
	}
	for _, body := range []map[string]any{{"response": "sure"}, {"response": "yes", "scope": "following"}, {"response": "yes", "extra": 1}} {
		if code, _ := call(t, e, tid, http.MethodPost, path+"/rsvp", mate, body); code != http.StatusBadRequest {
			t.Fatalf("a bad answer %v: %d", body, code)
		}
	}
	// A PATCH drops the agent: it leaves guests and mentions; the kept answer stays.
	code, out = call(t, e, tid, http.MethodPatch, path, dev, map[string]any{"guests": []any{calGuest("human", mate)}})
	if got := calEvent(t, out); code != http.StatusOK || len(calGuestAnswers(got)) != 1 || calGuestAnswers(got)[mate] != "maybe" ||
		calHas(got["mentions"], "c-042@box-a") || !calHas(got["mentions"], mate) {
		t.Fatalf("drop a guest: %d %v", code, out)
	}
}

// On a series: the default answers one occurrence, scope all the series.
func TestCalendarGuestsSeriesRoutes(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev, mate := seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
	calCreate(t, e, tid, dev, map[string]any{"title": "standup", "starts_at": "2026-10-19T06:00:00Z",
		"ends_at": "2026-10-19T06:30:00Z", "time_zone": "Europe/Helsinki", "rrule": "FREQ=WEEKLY;BYDAY=MO,WE;COUNT=6",
		"guests": []any{calGuest("human", mate)}})
	answers := func() []string {
		_, out := call(t, e, tid, http.MethodGet, calAutumnQuery, mate, nil)
		var rs []string
		for _, x := range calEvents(t, out) {
			rs = append(rs, x["my_response"].(string))
		}
		return rs
	}
	_, out := call(t, e, tid, http.MethodGet, calAutumnQuery, mate, nil)
	occ := calEvents(t, out)[2]["id"].(string)
	if code, out := call(t, e, tid, http.MethodPost, "/v1/calendar/events/"+occ+"/rsvp", mate, map[string]any{"response": "no"}); code != http.StatusOK {
		t.Fatalf("answer one occurrence: %d %v", code, out)
	}
	if rs := answers(); len(rs) != 6 || rs[2] != "no" || rs[0] != "needs_action" || rs[5] != "needs_action" {
		t.Fatalf("after this: %v", rs)
	}
	code, out := call(t, e, tid, http.MethodPost, "/v1/calendar/events/"+occ+"/rsvp", mate, map[string]any{"response": "yes", "scope": "all"})
	if code != http.StatusOK || calEvent(t, out)["id"] != occ {
		t.Fatalf("answer all: %d %v", code, out)
	}
	for _, r := range answers() {
		if r != "yes" {
			t.Fatalf("after all: %v", answers())
		}
	}
}

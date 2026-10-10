package hub_test

import (
	"bytes"
	"encoding/json"
	"maps"
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// specs/097 T004: the hub base of full editing. AC-01 (an 089 body answers
// 089's shape plus the new fields at their defaults), AC-02 (If-Match ->
// 409 edit_conflict), AC-03 (several typed reminders, remind_at both ways),
// the props registry (an unknown key is 400), and the soft delete with its
// restore and trash (spec 4.8).

// calendarIfMatch is call with an If-Match header ("" sends none).
func calendarIfMatch(t *testing.T, e *env, tid, method, path, as, ifMatch string, body any) (int, map[string]any) {
	t.Helper()
	var raw []byte
	if body != nil {
		raw, _ = json.Marshal(body)
	}
	req, _ := http.NewRequest(method, e.url(tid)+path, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set(memberHeader, as)
	if ifMatch != "" {
		req.Header.Set("If-Match", ifMatch)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
	return resp.StatusCode, out
}

func calEvent(t *testing.T, out map[string]any) map[string]any {
	t.Helper()
	ev, ok := out["event"].(map[string]any)
	if !ok {
		t.Fatalf("no event in %v", out)
	}
	return ev
}

// calReminders renders an event's reminders as "10 minutes,1 days".
func calReminders(ev map[string]any) string {
	var out []string
	list, _ := ev["reminders"].([]any)
	for _, x := range list {
		m := x.(map[string]any)
		if m["method"] != "popup" {
			return "bad method"
		}
		b, _ := json.Marshal(m["amount"])
		out = append(out, string(b)+" "+m["unit"].(string))
	}
	return strings.Join(out, ",")
}

// AC-01: c-394's "Add to calendar" body (msg-ai-actions.mjs aiEventBody).
func TestCalendarOldBodyNewDefaults(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	ev := calCreate(t, e, tid, dev, map[string]any{"title": "Deploy note", "description": "body\n\n---\n\nfrom #ops",
		"starts_at": "2026-10-06T10:00:00Z", "ends_at": "2026-10-06T11:00:00Z", "topic_id": "8c0f4e1a-1111-4222-8333-944455556666"})
	want089 := map[string]any{"source": "event", "title": "Deploy note", "kind": "other", "starts_at": "2026-10-06T10:00:00Z",
		"ends_at": "2026-10-06T11:00:00Z", "all_day": false, "audience": "workspace", "creator_type": "human", "creator_id": dev,
		"remind_at": "", "topic_id": "8c0f4e1a-1111-4222-8333-944455556666", "release_version": "", "issue_key": ""}
	for k, v := range want089 {
		if ev[k] != v {
			t.Errorf("089 field %s = %v, want %v", k, ev[k], v)
		}
	}
	defaults := map[string]any{"time_zone": "UTC", "rrule": "", "recurring_event_id": "", "original_start": "",
		"location": "", "color": "", "my_response": "", "deleted_at": "", "source_key": "", "roadmap_url": ""}
	for k, v := range defaults {
		if ev[k] != v {
			t.Errorf("new field %s = %v, want its default %v", k, ev[k], v)
		}
	}
	for _, k := range []string{"reminders", "guests", "mentions", "specs", "done_lines"} {
		if l, ok := ev[k].([]any); !ok || len(l) != 0 {
			t.Errorf("%s = %#v, want []", k, ev[k])
		}
	}
	keys := slices.Sorted(maps.Keys(ev))
	if len(keys) != 18+10+2+2 { // 089 6.1.1's 18 fields + 097 4.1's 10 + 112 HUB-1's source_key, roadmap_url + HUB-4's specs, done_lines
		t.Fatalf("event keys %v", keys)
	}
}

// AC-02: two PATCHes with the same If-Match: the second is 409 with the
// first one's result. DELETE honours it the same way.
func TestCalendarIfMatchEditConflict(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	a, b := seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
	ev := calCreate(t, e, tid, a, calBody("Standup", nil))
	path, v1 := "/v1/calendar/events/"+ev["id"].(string), `"`+ev["updated_at"].(string)+`"`

	code, out := calendarIfMatch(t, e, tid, http.MethodPatch, path, a, v1, map[string]any{"starts_at": "2026-10-06T09:30:00Z"})
	first := calEvent(t, out)
	if code != http.StatusOK || first["starts_at"] != "2026-10-06T09:30:00Z" {
		t.Fatalf("first PATCH: %d %v", code, out)
	}
	code, out = calendarIfMatch(t, e, tid, http.MethodPatch, path, b, v1, map[string]any{"starts_at": "2026-10-06T08:00:00Z"})
	if cur := calEvent(t, out); code != http.StatusConflict || out["error"] != "edit_conflict" ||
		cur["starts_at"] != "2026-10-06T09:30:00Z" || cur["updated_at"] != first["updated_at"] {
		t.Fatalf("second PATCH, stale If-Match: %d %v", code, out)
	}
	if code, out := calendarIfMatch(t, e, tid, http.MethodDelete, path, b, v1, nil); code != http.StatusConflict ||
		out["error"] != "edit_conflict" {
		t.Fatalf("DELETE, stale If-Match: %d %v", code, out)
	}
	if code, out := calendarIfMatch(t, e, tid, http.MethodPatch, path, b, "yesterday", map[string]any{"title": "x"}); code != http.StatusBadRequest {
		t.Fatalf("junk If-Match: %d %v", code, out)
	}
	// CONTROL: the current If-Match passes, and no header behaves as in 089.
	v2 := `"` + first["updated_at"].(string) + `"`
	if code, out := calendarIfMatch(t, e, tid, http.MethodPatch, path, b, v2, map[string]any{"title": "Standup 2"}); code != http.StatusOK {
		t.Fatalf("current If-Match: %d %v", code, out)
	}
	if code, out := calendarIfMatch(t, e, tid, http.MethodPatch, path, a, "", map[string]any{"title": "Standup 3"}); code != http.StatusOK {
		t.Fatalf("no If-Match: %d %v", code, out)
	}
}

// AC-03: reminders 10 minutes and 1 day read back as typed; /reminders
// answers one item per fire time; a fraction, 0, a string, a fifth week and
// a sixth reminder are 400; an old remind_at reads back as 15 minutes.
func TestCalendarSeveralReminders(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	two := []map[string]any{{"amount": 10, "unit": "minutes"}, {"amount": 1, "unit": "days", "method": "popup"},
		{"amount": 10, "unit": "minutes"}}
	ev := calCreate(t, e, tid, dev, calBody("Review", map[string]any{"starts_at": "2027-03-10T09:00:00Z",
		"ends_at": "2027-03-10T10:00:00Z", "reminders": two}))
	if got := calReminders(ev); got != "10 minutes,1 days" || ev["remind_at"] != "2027-03-09T09:00:00Z" {
		t.Fatalf("typed reminders: %q remind_at %v", got, ev["remind_at"])
	}
	_, out := call(t, e, tid, http.MethodGet, "/v1/calendar/reminders?from=2027-03-09T00:00:00Z&to=2027-03-11T00:00:00Z", dev, nil)
	var fires []string
	for _, x := range out["reminders"].([]any) {
		fires = append(fires, x.(map[string]any)["remind_at"].(string))
	}
	if strings.Join(fires, " ") != "2027-03-09T09:00:00Z 2027-03-10T08:50:00Z" {
		t.Fatalf("one item per fire time: %v", out)
	}
	// A move keeps each reminder as many minutes before the new start.
	path := "/v1/calendar/events/" + ev["id"].(string)
	if _, out := call(t, e, tid, http.MethodPatch, path, dev, map[string]any{"starts_at": "2027-03-10T12:00:00Z",
		"ends_at": "2027-03-10T13:00:00Z"}); calReminders(calEvent(t, out)) != "10 minutes,1 days" ||
		calEvent(t, out)["remind_at"] != "2027-03-09T12:00:00Z" {
		t.Fatalf("move: %v", out)
	}
	for _, bad := range []any{
		[]map[string]any{{"amount": 1.5, "unit": "hours"}},
		[]map[string]any{{"amount": 0, "unit": "minutes"}},
		[]map[string]any{{"amount": "10", "unit": "minutes"}},
		[]map[string]any{{"amount": 29, "unit": "days"}},
		[]map[string]any{{"amount": 40321, "unit": "minutes"}},
		[]map[string]any{{"amount": 1, "unit": "weeks"}},
		[]map[string]any{{"amount": 1, "unit": "days", "method": "email"}},
		[]map[string]any{{"amount": 1, "unit": "days"}, {"amount": 2, "unit": "days"}, {"amount": 3, "unit": "days"},
			{"amount": 4, "unit": "days"}, {"amount": 5, "unit": "days"}, {"amount": 6, "unit": "days"}},
	} {
		if code, out := call(t, e, tid, http.MethodPatch, path, dev, map[string]any{"reminders": bad}); code != http.StatusBadRequest ||
			out["error"] != "bad_event" {
			t.Errorf("reminders %v: %d %v, want 400 bad_event", bad, code, out)
		}
	}
	// CONTROL: the 4-week edge is accepted in each unit.
	edge := []map[string]any{{"amount": 40320, "unit": "minutes"}, {"amount": 672, "unit": "hours"}, {"amount": 28, "unit": "days"}}
	if code, out := call(t, e, tid, http.MethodPatch, path, dev, map[string]any{"reminders": edge}); code != http.StatusOK {
		t.Fatalf("4 weeks: %d %v", code, out)
	}
	// An 089 body with remind_at 15 minutes before the start.
	old := calCreate(t, e, tid, dev, calBody("Old", map[string]any{"remind_at": "2026-10-06T08:45:30Z"}))
	if calReminders(old) != "15 minutes" || old["remind_at"] != "2026-10-06T08:45:00Z" {
		t.Fatalf("remind_at as a reminder: %v", old)
	}
	if code, out := call(t, e, tid, http.MethodPost, "/v1/calendar/events", dev,
		calBody("Late", map[string]any{"remind_at": "2026-10-06T09:05:00Z"})); code != http.StatusBadRequest {
		t.Fatalf("remind_at after the start: %d %v", code, out)
	}
	if _, out := call(t, e, tid, http.MethodPatch, "/v1/calendar/events/"+old["id"].(string), dev,
		map[string]any{"remind_at": ""}); calReminders(calEvent(t, out)) != "" || calEvent(t, out)["remind_at"] != "" {
		t.Fatalf("remind_at \"\" clears: %v", out)
	}
}

// spec 3.3: the props registry. An unknown key is 400; location, color and
// time_zone are checked and read back.
func TestCalendarPropsRegistry(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	for _, bad := range []map[string]any{
		{"props": map[string]any{"busy": true}},
		{"props": map[string]any{"video_link": "https://example.com"}},
		{"color": "red"},
		{"props": map[string]any{"color": 3}},
		{"location": strings.Repeat("x", 301)},
		{"time_zone": "Mars/Olympus"},
		{"time_zone": "Local"},
	} {
		if code, out := call(t, e, tid, http.MethodPost, "/v1/calendar/events", dev, calBody("x", bad)); code != http.StatusBadRequest ||
			out["error"] != "bad_event" {
			t.Errorf("%v: %d %v, want 400 bad_event", bad, code, out)
		}
	}
	ev := calCreate(t, e, tid, dev, calBody("Offsite", map[string]any{"location": " Room 4 ", "color": "sage",
		"time_zone": "Europe/Helsinki", "props": map[string]any{"color": "tomato"}}))
	if ev["location"] != "Room 4" || ev["color"] != "sage" || ev["time_zone"] != "Europe/Helsinki" {
		t.Fatalf("props read back: %v", ev)
	}
	path := "/v1/calendar/events/" + ev["id"].(string)
	code, out := call(t, e, tid, http.MethodPatch, path, dev, map[string]any{"props": map[string]any{"location": ""}, "time_zone": ""})
	if ev := calEvent(t, out); code != http.StatusOK || ev["location"] != "" || ev["color"] != "sage" || ev["time_zone"] != "UTC" {
		t.Fatalf("reset location and zone, keep color: %d %v", code, out)
	}
}

// spec 4.8 (AC-07's hub half): DELETE is soft, the trash lists the caller's
// own deletions, restore brings the same id back; nobody else restores it.
func TestCalendarSoftDeleteRestoreTrash(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	a, b := seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
	ev := calCreate(t, e, tid, a, calBody("Retro", nil))
	id := ev["id"].(string)
	code, out := call(t, e, tid, http.MethodDelete, "/v1/calendar/events/"+id, a, nil)
	if del := calEvent(t, out); code != http.StatusOK || del["id"] != id || del["deleted_at"] == "" || del["title"] != "Retro" {
		t.Fatalf("soft delete: %d %v", code, out)
	}
	if _, out := call(t, e, tid, http.MethodGet, calWeekQuery, a, nil); calTitles(out, "events") != "" {
		t.Fatalf("a deleted event left the grid: %v", out)
	}
	if code, out := call(t, e, tid, http.MethodGet, "/v1/calendar/trash", a, nil); code != http.StatusOK || calTitles(out, "events") != "Retro" {
		t.Fatalf("a's trash: %d %v", code, out)
	}
	if _, out := call(t, e, tid, http.MethodGet, "/v1/calendar/trash", b, nil); calTitles(out, "events") != "" {
		t.Fatalf("b's trash shows a's deletion: %v", out)
	}
	if code, out := call(t, e, tid, http.MethodPost, "/v1/calendar/events/"+id+"/restore", b, nil); code != http.StatusNotFound {
		t.Fatalf("b restores a's deletion: %d %v", code, out)
	}
	code, out = call(t, e, tid, http.MethodPost, "/v1/calendar/events/"+id+"/restore", a, nil)
	if back := calEvent(t, out); code != http.StatusOK || back["id"] != id || back["deleted_at"] != "" {
		t.Fatalf("restore: %d %v", code, out)
	}
	if _, out := call(t, e, tid, http.MethodGet, calWeekQuery, b, nil); calTitles(out, "events") != "Retro" {
		t.Fatalf("restored event on the grid: %v", out)
	}
	if _, out := call(t, e, tid, http.MethodGet, "/v1/calendar/trash", a, nil); calTitles(out, "events") != "" {
		t.Fatalf("restored event still in the trash: %v", out)
	}
}

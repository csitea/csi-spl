package hub_test

import (
	"net/http"
	"net/url"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// specs/097 T009: GET /v1/calendar/search (spec 4.7). q matches title,
// description and location; kind, audience and guest filter; the private,
// demo and deleted filters apply as on every read; the cursor pages through;
// FR-001: an event made with the 089 body is found with 097's fields at
// their defaults.

const calSearchWeek = "&from=2026-10-05T00:00:00Z&to=2026-10-12T00:00:00Z"

func calSearch(t *testing.T, e *env, tid, as, query string) (int, map[string]any) {
	t.Helper()
	return call(t, e, tid, http.MethodGet, "/v1/calendar/search?"+query, as, nil)
}

func TestCalendarSearchFilters(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev, mate := seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
	old := calCreate(t, e, tid, dev, calBody("Ship v1.4", map[string]any{"kind": "release"})) // the 089 body
	calCreate(t, e, tid, dev, calBody("Freeze", map[string]any{"kind": "freeze", "description": "no SHIPping",
		"starts_at": "2026-10-07T09:00:00Z", "ends_at": "2026-10-07T10:00:00Z"}))
	calCreate(t, e, tid, mate, calBody("Standup", map[string]any{"location": "Ship room", "audience": "internal",
		"starts_at": "2026-10-08T09:00:00Z", "ends_at": "2026-10-08T10:00:00Z"}))
	calCreate(t, e, tid, dev, calBody("Secret ship", map[string]any{"audience": "private", "mentions": []string{"c-042"},
		"starts_at": "2026-10-09T09:00:00Z", "ends_at": "2026-10-09T10:00:00Z"}))
	gone := calCreate(t, e, tid, dev, calBody("Deleted ship", nil))
	if code, _ := call(t, e, tid, http.MethodDelete, "/v1/calendar/events/"+gone["id"].(string), dev, nil); code != http.StatusOK {
		t.Fatalf("delete: %d", code)
	}
	for _, c := range []struct{ what, as, query, want string }{
		{"text: title, description, location; private hidden", mate, "q=sHiP", "Ship v1.4,Freeze,Standup"},
		{"text: the private event's owner", dev, "q=ship", "Ship v1.4,Freeze,Standup,Secret ship"},
		{"kind repeats", dev, "kind=freeze&kind=release", "Ship v1.4,Freeze"},
		{"audience repeats", dev, "audience=internal&audience=private", "Standup,Secret ship"},
		{"guest: mention", dev, "guest=c-042", "Secret ship"},
		{"guest: owner", dev, "guest=" + mate, "Standup"},
		{"guest: a non-guest finds no private event", mate, "guest=c-042", ""},
	} {
		code, out := calSearch(t, e, tid, c.as, c.query+calSearchWeek)
		if code != http.StatusOK || calTitles(out, "events") != c.want || out["next_cursor"] != "" {
			t.Fatalf("%s: %d %q want %q (%v)", c.what, code, calTitles(out, "events"), c.want, out)
		}
	}
	// FR-001: the 089 event comes back with 097's fields at their defaults.
	_, out := calSearch(t, e, tid, dev, "q=v1.4"+calSearchWeek)
	ev := out["events"].([]any)[0].(map[string]any)
	if ev["id"] != old["id"] || ev["time_zone"] != "UTC" || ev["source"] != "event" || ev["deleted_at"] != "" ||
		len(ev["guests"].([]any)) != 0 || len(ev["reminders"].([]any)) != 0 {
		t.Fatalf("089 event in search: %v", ev)
	}
}

func TestCalendarSearchCursor(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	for _, title := range []string{"a", "b", "c", "d", "e"} {
		calCreate(t, e, tid, dev, calBody(title, nil)) // one start time: the id breaks the tie
	}
	seen, cursor := map[string]bool{}, ""
	for page := 0; ; page++ {
		code, out := calSearch(t, e, tid, dev, "limit=2&cursor="+url.QueryEscape(cursor)+calSearchWeek)
		if code != http.StatusOK || page > 3 {
			t.Fatalf("page %d: %d %v", page, code, out)
		}
		for _, x := range out["events"].([]any) {
			id := x.(map[string]any)["id"].(string)
			if seen[id] {
				t.Fatalf("page %d repeats %s", page, id)
			}
			seen[id] = true
		}
		if cursor = out["next_cursor"].(string); cursor == "" {
			break
		}
	}
	if len(seen) != 5 {
		t.Fatalf("paged %d of 5", len(seen))
	}
}

// from / to default to a year around now: the hub's clock, not the caller's.
func TestCalendarSearchDefaultRange(t *testing.T) {
	now := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	e := rbacEnv(t, func(o *hub.Options) { o.Now = func() time.Time { return now } })
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	calCreate(t, e, tid, dev, calBody("Near", nil))
	calCreate(t, e, tid, dev, calBody("Far", map[string]any{"starts_at": "2028-10-06T09:00:00Z", "ends_at": "2028-10-06T10:00:00Z"}))
	if code, out := calSearch(t, e, tid, dev, ""); code != http.StatusOK || calTitles(out, "events") != "Near" {
		t.Fatalf("default range: %d %v", code, out)
	}
	if _, out := calSearch(t, e, tid, dev, "to=2029-01-01T00:00:00Z"); calTitles(out, "events") != "Near,Far" {
		t.Fatalf("CONTROL wider to: %v", out)
	}
}

func TestCalendarSearchRefusals(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	long := make([]byte, 201)
	for i := range long {
		long[i] = 'x'
	}
	for _, c := range []struct{ query, token string }{
		{"limit=0", "bad_query"},
		{"limit=101", "bad_query"},
		{"limit=x", "bad_query"},
		{"audience=secret", "bad_query"},
		{"q=" + string(long), "bad_query"},
		{"cursor=not-a-cursor", "bad_cursor"},
		{"from=yesterday", "bad_range"},
		{"from=2026-10-06T00:00:00Z&to=2026-10-05T00:00:00Z", "bad_range"},
		{"from=2020-01-01T00:00:00Z&to=2026-01-02T00:00:00Z", "bad_range"},
	} {
		if code, out := calSearch(t, e, tid, dev, c.query); code != http.StatusBadRequest || out["error"] != c.token {
			t.Fatalf("%s: %d %v", c.query, code, out)
		}
	}
	if code, out := calSearch(t, e, tid, dev, "limit=100&from=2021-01-02T00:00:00Z&to=2026-01-02T00:00:00Z"); code != http.StatusOK {
		t.Fatalf("CONTROL 5 years, limit 100: %d %v", code, out)
	}
}

// A demo visitor finds workspace and public events only, whatever audience it asks for.
func TestCalendarSearchDemoPublicOnly(t *testing.T) {
	e, demo := demoEnv(t)
	dev, visitor := seat(t, e, demo, rbac.Developer), seat(t, e, demo, rbac.DemoUser)
	calCreate(t, e, demo, dev, calBody("Open", nil))
	calCreate(t, e, demo, dev, calBody("Team", map[string]any{"audience": "internal"}))
	calCreate(t, e, demo, dev, calBody("Own", map[string]any{"audience": "private", "mentions": []string{visitor}}))
	for _, q := range []string{"", "audience=internal&audience=workspace", "q=o"} {
		if code, out := calSearch(t, e, demo, visitor, q+calSearchWeek); code != http.StatusOK || calTitles(out, "events") != "Open" {
			t.Fatalf("demo %q: %d %v", q, code, out)
		}
	}
	if _, out := calSearch(t, e, demo, visitor, "audience=private"+calSearchWeek); calTitles(out, "events") != "" {
		t.Fatalf("demo asks for private: %v", out)
	}
	if _, out := calSearch(t, e, demo, dev, calSearchWeek); len(out["events"].([]any)) != 3 {
		t.Fatalf("CONTROL: the developer finds all three: %v", out)
	}
}

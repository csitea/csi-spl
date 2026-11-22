package hub_test

import (
	"net/http"
	"net/url"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Spec 100 section 15 (SPL-6251): type:calendar (also cal, calendars) finds
// the workspace's calendar entries in GET /v1/view/search, through the
// calendar search's own store query: a private entry only for its people, a
// deleted one never, a demo visitor workspace and public only. type:event
// stays the event log; a plain search reads no calendar. Memory, and
// Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

// calSearchBody is an entry three days from now at hour h (the search's order
// is by start), inside the search's range (one year either side of now)
// whenever the test runs.
func calSearchBody(title string, h int, extra map[string]any) map[string]any {
	at := time.Now().UTC().AddDate(0, 0, 3).Truncate(24 * time.Hour).Add(time.Duration(h) * time.Hour)
	b := map[string]any{"starts_at": at.Format(time.RFC3339), "ends_at": at.Add(time.Hour).Format(time.RFC3339)}
	for k, v := range extra {
		b[k] = v
	}
	return calBody(title, b)
}

// searchCalendars runs q as the member and answers the status, the answer's
// types, the calendars group's entry ids and its next cursor.
func searchCalendars(t *testing.T, e *env, tid, as, q, extra string) (int, []string, []string, string) {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/view/search?q="+url.QueryEscape(q)+extra, as, nil)
	if code != http.StatusOK {
		return code, nil, nil, ""
	}
	var types, ids []string
	for _, x := range out["types"].([]any) {
		types = append(types, x.(string))
	}
	groups, _ := out["groups"].(map[string]any)
	sec, _ := groups["calendars"].(map[string]any)
	rs, _ := sec["results"].([]any)
	for _, r := range rs {
		ids = append(ids, r.(map[string]any)["id"].(string))
	}
	next, _ := sec["next"].(string)
	return code, types, ids, next
}

func TestSearchTypeCalendar(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev, mate := seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
	flight := calCreate(t, e, tid, dev, calSearchBody("Flight SQ323 to Riga", 9, map[string]any{"description": "window seat"}))["id"].(string)
	lounge := calCreate(t, e, tid, dev, calSearchBody("Lounge", 10, map[string]any{"location": "Gate sq323"}))["id"].(string)
	secret := calCreate(t, e, tid, mate, calSearchBody("Secret SQ323 visit", 11, map[string]any{"audience": "private"}))["id"].(string)
	gone := calCreate(t, e, tid, dev, calSearchBody("Old SQ323", 12, nil))["id"].(string)
	calCreate(t, e, tid, dev, calSearchBody("Standup", 13, nil))
	if code, _ := call(t, e, tid, http.MethodDelete, "/v1/calendar/events/"+gone, dev, nil); code != http.StatusOK {
		t.Fatalf("delete: %d", code)
	}
	for _, c := range []struct {
		what, as, q string
		want        []string
	}{
		{"type:calendar: title and location; another's private and the deleted never", dev, "type:calendar SQ323", []string{flight, lounge}},
		{"type:cal", dev, "type:cal SQ323", []string{flight, lounge}},
		{"type:calendars, case folded", dev, "type:calendars sq323", []string{flight, lounge}},
		{"the private entry's creator finds it", mate, "type:calendar SQ323", []string{flight, lounge, secret}},
		{"the description", dev, "type:cal window", []string{flight}},
		{"two words, the shorter one filtered", dev, "type:cal riga SQ323", []string{flight}},
		{"NOT", dev, "type:cal SQ323 -riga", []string{lounge}},
		{"name: is the title", dev, "type:cal name:lounge", []string{lounge}},
		{"no match", dev, "type:cal nowhere", nil},
	} {
		code, types, ids, _ := searchCalendars(t, e, tid, c.as, c.q, "")
		if code != http.StatusOK || !slices.Equal(types, []string{"calendar"}) || !slices.Equal(ids, c.want) {
			t.Fatalf("%s: %q = %d types %v ids %v, want [calendar] %v", c.what, c.q, code, types, ids, c.want)
		}
	}
	// CONTROL: type:event stays the event log, and a plain search reads no calendar
	for _, q := range []string{"type:event SQ323", "SQ323"} {
		code, types, ids, _ := searchCalendars(t, e, tid, dev, q, "")
		if code != http.StatusOK || slices.Contains(types, "calendar") || ids != nil {
			t.Fatalf("CONTROL %q = %d types %v ids %v, want no calendar section", q, code, types, ids)
		}
	}
	// paged by the store's keyset: one entry, then the next by the cursor
	_, _, first, next := searchCalendars(t, e, tid, mate, "type:calendar SQ323", "&limit=2")
	if len(first) != 2 || next == "" {
		t.Fatalf("page 1: %v next %q, want 2 and a cursor", first, next)
	}
	_, _, rest, last := searchCalendars(t, e, tid, mate, "type:calendar SQ323", "&limit=2&cursor="+url.QueryEscape(next))
	if !slices.Equal(append(first, rest...), []string{flight, lounge, secret}) || last != "" {
		t.Fatalf("page 2: %v then %v (next %q), want every entry once", first, rest, last)
	}
}

// The row: the title highlighted, the time, the place; it opens the entry.
func TestSearchTypeCalendarRow(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	ev := calCreate(t, e, tid, dev, calSearchBody("Flight SQ323", 14, map[string]any{"location": "Terminal 2", "kind": "release"}))
	_, out := call(t, e, tid, http.MethodGet, "/v1/view/search?q="+url.QueryEscape("type:cal sq323"), dev, nil)
	row := out["groups"].(map[string]any)["calendars"].(map[string]any)["results"].([]any)[0].(map[string]any)
	title := row["title"].(map[string]any)
	hs := title["highlights"].([]any)
	if row["id"] != ev["id"] || row["starts_at"] != ev["starts_at"] || row["ends_at"] != ev["ends_at"] ||
		row["location"] != "Terminal 2" || row["kind"] != "release" || row["all_day"] != false ||
		title["text"] != "Flight SQ323" || len(hs) != 1 {
		t.Fatalf("row %v, want the entry's id, times, place and the title highlighted once", row)
	}
}

// A demo visitor finds workspace and public entries only, as on the calendar.
func TestSearchTypeCalendarDemo(t *testing.T) {
	e, demo := demoEnv(t)
	dev, visitor := seat(t, e, demo, rbac.Developer), seat(t, e, demo, rbac.DemoUser)
	open := calCreate(t, e, demo, dev, calSearchBody("Open SQ323", 15, nil))["id"].(string)
	calCreate(t, e, demo, dev, calSearchBody("Team SQ323", 16, map[string]any{"audience": "internal"}))
	calCreate(t, e, demo, dev, calSearchBody("Own SQ323", 17, map[string]any{"audience": "private", "mentions": []string{visitor}}))
	if _, _, ids, _ := searchCalendars(t, e, demo, visitor, "type:cal SQ323", ""); !slices.Equal(ids, []string{open}) {
		t.Fatalf("demo visitor: %v, want [%s] only", ids, open)
	}
	if _, _, ids, _ := searchCalendars(t, e, demo, dev, "type:cal SQ323", ""); len(ids) != 3 {
		t.Fatalf("CONTROL: the developer finds all three (the private one is theirs): %v", ids)
	}
}

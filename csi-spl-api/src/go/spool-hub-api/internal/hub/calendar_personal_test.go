package hub_test

import (
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-5963 (owner HUM-10, msg eac307d4, spec 089 section 4.2): an entry an
// agent writes for one person is private to that person by default, and an
// issue deadline shows on the calendar only to its assignee and its creator.
// Members A and B share one workspace; B never reads A's personal entries.
// Memory, and Postgres under SPOOL_TEST_PG_DSN.

const personalDay = "/v1/calendar/events?start=2027-03-01T00:00:00Z&end=2027-03-02T00:00:00Z"

// opCreate writes one whole-day event on 2027-03-01 as agent c-840 and
// answers the event as the hub stored it.
func opCreate(t *testing.T, e *env, tid string, extra map[string]any) map[string]any {
	t.Helper()
	body := map[string]any{"tenant": tid, "agent_id": "c-840", "all_day": true,
		"starts_at": "2027-03-01T00:00:00Z", "ends_at": "2027-03-02T00:00:00Z"}
	for k, v := range extra {
		body[k] = v
	}
	code, out := opCall(t, e, tid, http.MethodPost, "/v1/operator/calendar/events", "good", body)
	ev, _ := out["event"].(map[string]any)
	if code != http.StatusCreated || ev == nil {
		t.Fatalf("operator create %v: %d %v", body["title"], code, out)
	}
	return ev
}

// sortedTitles is who's range read of personalDay, titles sorted.
func sortedTitles(t *testing.T, e *env, tid, who string) string {
	t.Helper()
	_, out := call(t, e, tid, http.MethodGet, personalDay, who, nil)
	got := strings.Split(calTitles(out, "events"), ",")
	slices.Sort(got)
	return strings.Join(got, ",")
}

func TestOperatorCalendarPersonalEntryDefaultsPrivate(t *testing.T) {
	e := opWriteEnv(t)
	tid, _ := e.tenant()
	a, b := seat(t, e, tid, rbac.BizOwner), seat(t, e, tid, rbac.BizOwner)

	trip := opCreate(t, e, tid, map[string]any{"title": "Trip", "ordered_by": a})
	if trip["audience"] != "private" || strings.Join(toStrings(trip["mentions"]), ",") != a || trip["owner_id"] != a {
		t.Fatalf("an agent's entry for one person is not private to that person: %v", trip)
	}
	forB := opCreate(t, e, tid, map[string]any{"title": "ForB", "ordered_by": a, "owner_id": b})
	if forB["audience"] != "private" || strings.Join(toStrings(forB["mentions"]), ",") != b {
		t.Fatalf("an entry owned by b is not private to b: %v", forB)
	}
	opCreate(t, e, tid, map[string]any{"title": "Team", "ordered_by": a, "audience": "workspace"})
	opCreate(t, e, tid, map[string]any{"title": "Agents"}) // no person: the agent owns it, workspace as before

	for who, want := range map[string]string{a: "Agents,Team,Trip", b: "Agents,ForB,Team"} {
		if got := sortedTitles(t, e, tid, who); got != want {
			t.Fatalf("%s reads %s, want %s", who, got, want)
		}
	}
	// The agent reads its private entry back (do_spl_calendar_event_add's read-back).
	if code, out := opCall(t, e, tid, http.MethodGet, "/v1/operator/calendar/events/"+trip["id"].(string)+"?tenant="+tid+"&as=c-840", "good", nil); code != http.StatusOK {
		t.Fatalf("read-back as the agent: %d %v", code, out)
	}
}

// R1: the operator PATCH narrows an agent's shared entry made for ordered_by
// to private for that person, and nothing else.
func TestOperatorCalendarNarrowsToPrivate(t *testing.T) {
	e := opWriteEnv(t)
	tid, _ := e.tenant()
	a, b := seat(t, e, tid, rbac.BizOwner), seat(t, e, tid, rbac.BizOwner)
	trip := opCreate(t, e, tid, map[string]any{"title": "Trip", "ordered_by": a, "audience": "workspace"})["id"].(string)
	opCreate(t, e, tid, map[string]any{"title": "Other", "ordered_by": a, "audience": "workspace"})
	human := calCreate(t, e, tid, a, map[string]any{"title": "Own", "all_day": true,
		"starts_at": "2027-03-01T00:00:00Z", "ends_at": "2027-03-02T00:00:00Z"})["id"].(string)
	patch := func(id string, body map[string]any) (int, map[string]any) {
		bd := map[string]any{"tenant": tid, "agent_id": "c-841"}
		for k, v := range body {
			bd[k] = v
		}
		return opCall(t, e, tid, http.MethodPatch, "/v1/operator/calendar/events/"+id, "good", bd)
	}
	for _, c := range []struct {
		name string
		id   string
		body map[string]any
	}{
		{"widening to workspace", trip, map[string]any{"ordered_by": a, "audience": "workspace"}},
		{"no ordered_by", trip, map[string]any{"audience": "private"}},
		{"ordered_by is not the owner", trip, map[string]any{"ordered_by": b, "audience": "private"}},
		{"a human's own entry", human, map[string]any{"ordered_by": a, "audience": "private"}},
	} {
		if code, out := patch(c.id, c.body); code != http.StatusBadRequest {
			t.Fatalf("PATCH %s: %d %v, want 400", c.name, code, out)
		}
	}
	if got := sortedTitles(t, e, tid, b); got != "Other,Own,Trip" {
		t.Fatalf("a refused PATCH changed what b reads: %s", got)
	}
	code, out := patch(trip, map[string]any{"ordered_by": a, "audience": "private"})
	ev, _ := out["event"].(map[string]any)
	if code != http.StatusOK || ev["audience"] != "private" || strings.Join(toStrings(ev["mentions"]), ",") != a {
		t.Fatalf("narrow to private: %d %v", code, out)
	}
	if got := sortedTitles(t, e, tid, b); got != "Other,Own" {
		t.Fatalf("b still reads a's narrowed entry: %s", got)
	}
	if got := sortedTitles(t, e, tid, a); got != "Other,Own,Trip" {
		t.Fatalf("a lost an entry: %s", got)
	}
}

func TestCalendarDeadlineOnlyToAssigneeAndCreator(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	creator, assignee, other := seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", creator, map[string]any{"title": "Auth", "kind": "epic"}); code != http.StatusCreated {
		t.Fatalf("epic: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", creator, map[string]any{"epic": "SPL-1",
		"title": "Due", "assignee": assignee, "deadline": "2026-10-07T15:00:00Z"}); code != http.StatusCreated {
		t.Fatalf("issue: %d %v", code, out)
	}
	marks := func(who string) string {
		_, out := call(t, e, tid, http.MethodGet, "/v1/calendar/marks?start_year=2026&end_year=2026", who, nil)
		var got []string
		for _, x := range out["days"].([]any) {
			m := x.(map[string]any)
			got = append(got, m["day"].(string)+":"+strings.Join(toStrings(m["kinds"]), "+"))
		}
		return strings.Join(got, " ")
	}
	for who, want := range map[string]string{creator: "Due", assignee: "Due", other: ""} {
		if _, out := call(t, e, tid, http.MethodGet, calWeekQuery, who, nil); calTitles(out, "events") != want {
			t.Fatalf("range read: %s reads %q, want %q", who, calTitles(out, "events"), want)
		}
		wantMarks := ""
		if want != "" {
			wantMarks = "2026-10-07:deadline"
		}
		if got := marks(who); got != wantMarks {
			t.Fatalf("marks: %s reads %q, want %q", who, got, wantMarks)
		}
	}
}

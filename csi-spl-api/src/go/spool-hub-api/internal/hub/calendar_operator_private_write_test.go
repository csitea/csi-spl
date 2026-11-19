package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-5720 (spec 097 section 4.10): an agent replaces a private entry an
// agent made for a person. With ordered_by = that person (a member, named in
// the mentions), the operator PATCH changes it (reminders, title), the GET
// reads it back, and the DELETE moves it to the person's trash. CONTROLS,
// each 404 and changing nothing: the person's own private entry, an agent's
// private entry for another person, another person's private entry that
// names the person, and the agent's entry with no ordered_by or with a
// non-member one. Memory, and Postgres under SPOOL_TEST_PG_DSN.
func TestOperatorCalendarReplacesAgentPrivate(t *testing.T) {
	e := opWriteEnv(t)
	ta, _ := e.tenant()
	boss, her := seat(t, e, ta, rbac.Developer), seat(t, e, ta, rbac.Developer)
	const day = "/v1/calendar/events?start=2027-02-01T00:00:00Z&end=2027-02-02T00:00:00Z"
	agentPrivate := func(title, person string) string {
		code, out := opCall(t, e, ta, http.MethodPost, "/v1/operator/calendar/events", "good", map[string]any{
			"tenant": ta, "agent_id": "c-840", "ordered_by": person, "title": title, "all_day": true,
			"audience": "private", "mentions": []any{person},
			"starts_at": "2027-02-01T00:00:00Z", "ends_at": "2027-02-02T00:00:00Z"})
		ev, _ := out["event"].(map[string]any)
		if code != http.StatusCreated || ev == nil || ev["audience"] != "private" {
			t.Fatalf("agent private %s: %d %v", title, code, out)
		}
		return ev["id"].(string)
	}
	mine := agentPrivate("Trip", boss)
	hers := agentPrivate("Hers", her)
	own := calCreate(t, e, ta, boss, map[string]any{"title": "Own", "all_day": true, "audience": "private",
		"starts_at": "2027-02-01T00:00:00Z", "ends_at": "2027-02-02T00:00:00Z"})["id"].(string)
	herOwn := calCreate(t, e, ta, her, map[string]any{"title": "HerOwn", "all_day": true, "audience": "private",
		"mentions": []any{boss}, "starts_at": "2027-02-01T00:00:00Z", "ends_at": "2027-02-02T00:00:00Z"})["id"].(string)

	patch := func(id string, body map[string]any) (int, map[string]any) {
		b := map[string]any{"tenant": ta, "agent_id": "c-841"}
		for k, v := range body {
			b[k] = v
		}
		return opCall(t, e, ta, http.MethodPatch, "/v1/operator/calendar/events/"+id, "good", b)
	}
	change := map[string]any{"ordered_by": boss, "title": "Trip, 15 min alert",
		"reminders": []any{map[string]any{"amount": 15, "unit": "minutes", "method": "popup"}}}
	byBoss := "tenant=" + ta + "&agent_id=c-841&ordered_by=" + boss
	for _, c := range []struct {
		name, id, orderedBy string
	}{
		{"the person's own private entry", own, boss},
		{"an agent's private entry for another person", hers, boss},
		{"another person's private entry naming the person", herOwn, boss},
		{"no ordered_by", mine, ""},
		{"a non-member ordered_by", mine, "HUM-99999"},
	} {
		body := map[string]any{"title": "x"}
		q := "tenant=" + ta + "&agent_id=c-841"
		if c.orderedBy != "" {
			body["ordered_by"], q = c.orderedBy, q+"&ordered_by="+c.orderedBy
		}
		if code, got := patch(c.id, body); code != http.StatusNotFound {
			t.Fatalf("PATCH %s: %d %v, want 404", c.name, code, got)
		}
		if code, got := opCall(t, e, ta, http.MethodDelete, "/v1/operator/calendar/events/"+c.id+"?"+q, "good", nil); code != http.StatusNotFound {
			t.Fatalf("DELETE %s: %d %v, want 404", c.name, code, got)
		}
		if c.orderedBy != "" {
			if code, got := opCall(t, e, ta, http.MethodGet, "/v1/operator/calendar/events/"+c.id+"?tenant="+ta+"&ordered_by="+c.orderedBy, "good", nil); code != http.StatusNotFound {
				t.Fatalf("GET %s: %d %v, want 404", c.name, code, got)
			}
		}
	}
	// boss reads Trip, Own and HerOwn; her reads Hers and HerOwn: all as written.
	for who, n := range map[string]int{boss: 3, her: 2} {
		_, got := call(t, e, ta, http.MethodGet, day, who, nil)
		evs, _ := got["events"].([]any)
		for _, x := range evs {
			if tt := x.(map[string]any)["title"]; tt == "x" {
				t.Fatalf("a refusal wrote: %v", got)
			}
		}
		if len(evs) != n {
			t.Fatalf("%s reads %d entries, want %d: %v", who, len(evs), n, got)
		}
	}
	// Nothing widens an audience (SPL-5963: the operator only narrows to
	// private); mentions stay the members'.
	if code, got := patch(mine, map[string]any{"ordered_by": boss, "audience": "workspace"}); code != http.StatusBadRequest || got["error"] != "bad_event" {
		t.Fatalf("PATCH audience workspace: %d %v, want 400 bad_event", code, got)
	}
	if code, got := patch(mine, map[string]any{"ordered_by": boss, "mentions": []any{boss, her}}); code != http.StatusBadRequest || got["error"] != "bad_json" {
		t.Fatalf("PATCH mentions: %d %v, want 400 bad_json", code, got)
	}

	// The change: title and a 15-minute reminder, still private, still the agent's.
	code, out := patch(mine, change)
	ev, _ := out["event"].(map[string]any)
	if code != http.StatusOK || ev["title"] != "Trip, 15 min alert" || ev["audience"] != "private" || ev["creator_id"] != "c-840" {
		t.Fatalf("PATCH the agent's private entry: %d %v", code, out)
	}
	if rs, _ := ev["reminders"].([]any); len(rs) != 1 || rs[0].(map[string]any)["unit"] != "minutes" {
		t.Fatalf("reminders after PATCH: %v", ev["reminders"])
	}
	get := "/v1/operator/calendar/events/" + mine + "?tenant=" + ta
	if code, got := opCall(t, e, ta, http.MethodGet, get+"&ordered_by="+boss, "good", nil); code != http.StatusOK ||
		got["event"].(map[string]any)["title"] != "Trip, 15 min alert" {
		t.Fatalf("read back with ordered_by: %d %v", code, got)
	}
	if code, _ := opCall(t, e, ta, http.MethodGet, get, "good", nil); code != http.StatusNotFound {
		t.Fatalf("read back with no viewer: %d, want 404", code)
	}
	if code, _ := opCall(t, e, ta, http.MethodGet, get+"&as=c-840&ordered_by="+boss, "good", nil); code != http.StatusBadRequest {
		t.Fatalf("as and ordered_by: %d, want 400", code)
	}

	// The delete: into the person's trash, out of the day; Undo is theirs.
	if code, got := opCall(t, e, ta, http.MethodDelete, "/v1/operator/calendar/events/"+mine+"?"+byBoss, "good", nil); code != http.StatusOK ||
		got["event"].(map[string]any)["deleted_at"] == "" {
		t.Fatalf("DELETE the agent's private entry: %d %v", code, got)
	}
	if _, got := call(t, e, ta, http.MethodGet, "/v1/calendar/trash", boss, nil); calTitles(got, "events") != "Trip, 15 min alert" {
		t.Fatalf("the person's trash: %v", got)
	}
	if _, got := call(t, e, ta, http.MethodGet, day, boss, nil); len(got["events"].([]any)) != 2 {
		t.Fatalf("after the delete the person's day: %v", got)
	}
	if code, _ := opCall(t, e, ta, http.MethodGet, get+"&ordered_by="+boss, "good", nil); code != http.StatusNotFound {
		t.Fatalf("read back of the trashed entry: %d, want 404", code)
	}
	if code, _ := call(t, e, ta, http.MethodPost, "/v1/calendar/events/"+mine+"/restore", boss, nil); code != http.StatusOK {
		t.Fatalf("the person's Undo: %d", code)
	}
}

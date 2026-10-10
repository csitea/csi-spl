package hub_test

import (
	"encoding/json"
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// specs/112 HUB-4: the reads return a synced event's goal fields. (a) The
// member event JSON carries specs and done_lines from props, top-level like
// roadmap_url, [] on a member's own event. (b) The signed-out read adds
// source_key, roadmap_url, specs and done_lines to a synced event of a
// PUBLIC roadmap only: an internal roadmap's event is not read at all, and a
// member's public event keeps the five fields. Memory, and Postgres under
// SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

// goalSync writes one goal deadline event (with specs and done lines) and
// one milestone (with neither) into tid, inside webCalQuery's week.
func goalSync(t *testing.T, e *env, tid, approver string) {
	t.Helper()
	ev := syncEv(tid, "goal:G01:deadline", "2026-10-08")
	ev["specs"], ev["done_lines"] = []string{"089", "112"}, []string{"100% of specs are [x]"}
	goals := []map[string]any{syncGoal(tid, "G01-first", approvalMsg(t, e, tid, approver, ""))}
	if code, out := syncCall(t, e, tid, goals, []map[string]any{ev, syncEv(tid, "goal:G01:m:start", "2026-10-07")}); code != http.StatusOK {
		t.Fatalf("sync: %d %v", code, out)
	}
}

// goalFields is ev's four goal keys as JSON, "-" for an absent one.
func goalFields(ev map[string]any) string {
	var out []string
	for _, k := range []string{"source_key", "roadmap_url", "specs", "done_lines"} {
		v, ok := ev[k]
		if !ok {
			out = append(out, "-")
			continue
		}
		b, _ := json.Marshal(v)
		out = append(out, string(b))
	}
	return strings.Join(out, " ")
}

// byTitle is the events keyed by their title.
func byTitle(evs []map[string]any) map[string]map[string]any {
	out := map[string]map[string]any{}
	for _, ev := range evs {
		out[ev["title"].(string)] = ev
	}
	return out
}

const (
	wantDeadline  = `"goal:G01:deadline" "/roadmap?goal=G01" ["089","112"] ["100% of specs are [x]"]`
	wantMilestone = `"goal:G01:m:start" "/roadmap?goal=G01" [] []`
)

func TestCalendarGoalFieldsMemberRead(t *testing.T) {
	e, tid := syncEnv(t)
	admin := seat(t, e, tid, rbac.Admin)
	goalSync(t, e, tid, admin)
	calCreate(t, e, tid, admin, calBody("Mine", nil))
	code, out := call(t, e, tid, http.MethodGet, "/v1/calendar/events?start=2026-10-05T00:00:00Z&end=2026-10-12T00:00:00Z", admin, nil)
	raw, _ := out["events"].([]any)
	var evs []map[string]any
	for _, x := range raw {
		evs = append(evs, x.(map[string]any))
	}
	got := byTitle(evs)
	if code != http.StatusOK || len(got) != 3 {
		t.Fatalf("member read: %d %v", code, out)
	}
	for title, want := range map[string]string{"goal:G01:deadline": wantDeadline, "goal:G01:m:start": wantMilestone,
		"Mine": `"" "" [] []`} {
		if g := goalFields(got[title]); g != want {
			t.Errorf("%s goal fields:\n got %s\nwant %s", title, g, want)
		}
	}
}

func TestCalendarGoalFieldsSignedOut(t *testing.T) {
	e, pub := syncEnv(t)
	internal := syncWorkspace(t, e)
	for _, tid := range []string{pub, internal} {
		owner := seat(t, e, tid, rbac.BizOwner)
		goalSync(t, e, tid, owner)
		calCreate(t, e, tid, owner, calBody(tid+"-open", map[string]any{"audience": "public"}))
		if tid == pub {
			if code, out := call(t, e, tid, http.MethodPatch, "/v1/workspaces/"+tid+"/roadmap", owner, map[string]any{"public": true}); code != http.StatusOK {
				t.Fatalf("switch: %d %v", code, out)
			}
		}
	}

	// (b) public roadmap: both synced events with the four fields, the
	// member's public event with the five safe fields only.
	code, evs, _ := webCalGet(t, e, pub+domain, "", webCalQuery)
	got := byTitle(evs)
	if code != http.StatusOK || len(got) != 3 {
		t.Fatalf("signed-out read of the public roadmap = %d %v", code, evs)
	}
	for title, want := range map[string]string{"goal:G01:deadline": wantDeadline, "goal:G01:m:start": wantMilestone,
		pub + "-open": "- - - -"} {
		if g := goalFields(got[title]); g != want {
			t.Errorf("%s goal fields:\n got %s\nwant %s", title, g, want)
		}
	}
	keys := slices.Sorted(func(yield func(string) bool) {
		for k := range got["goal:G01:deadline"] {
			if !yield(k) {
				return
			}
		}
	})
	if j := strings.Join(keys, ","); j != "all_day,description,done_lines,ends_at,roadmap_url,source_key,specs,starts_at,title" {
		t.Fatalf("a public synced event = %s, want the five safe fields and the four goal fields only", j)
	}

	// (b) internal roadmap: no synced event and none of the four fields.
	code, evs, _ = webCalGet(t, e, internal+domain, "", webCalQuery)
	if code != http.StatusOK || webCalTitles(evs) != internal+"-open" || goalFields(evs[0]) != "- - - -" {
		t.Fatalf("signed-out read of the internal roadmap = %d %v, want only %s-open with no goal field", code, evs, internal)
	}
}

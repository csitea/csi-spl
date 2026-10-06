package hub_test

import (
	"go/ast"
	"go/parser"
	"go/token"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// specs/089 T004: the calendar routes (spec section 6, wire format 6.1) over
// the real role table. Public by default; only the event's owner moves an
// event to or from private (FR-010, AC-09), an admin and the workspace owner
// included; a demo visitor reads public events only and writes nothing;
// reminders hold only what the viewer owns or is named on; issue deadlines
// join the range answer; nothing in the path sends a message (D4).

const calWeekQuery = "/v1/calendar/events?start=2026-10-05T00:00:00Z&end=2026-10-12T00:00:00Z"

func calBody(title string, extra map[string]any) map[string]any {
	b := map[string]any{"title": title, "starts_at": "2026-10-06T09:00:00Z", "ends_at": "2026-10-06T10:00:00+00:00"}
	for k, v := range extra {
		b[k] = v
	}
	return b
}

func calCreate(t *testing.T, e *env, tid, as string, body map[string]any) map[string]any {
	t.Helper()
	code, out := call(t, e, tid, http.MethodPost, "/v1/calendar/events", as, body)
	ev, ok := out["event"].(map[string]any)
	if code != http.StatusCreated || !ok {
		t.Fatalf("create %v as %s: %d %v", body["title"], as, code, out)
	}
	return ev
}

// calTitles lists the titles of an answer's list under key.
func calTitles(out map[string]any, key string) string {
	var ts []string
	list, _ := out[key].([]any)
	for _, x := range list {
		ts = append(ts, x.(map[string]any)["title"].(string))
	}
	return strings.Join(ts, ",")
}

func TestCalendarPublicDefaultOwnerOnlyPrivate(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev, mate := seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
	admin, owner := seat(t, e, tid, rbac.Admin), seat(t, e, tid, rbac.BizOwner)

	ev := calCreate(t, e, tid, dev, calBody("Ship", map[string]any{"kind": "release", "release_version": "v1.4.0"}))
	if ev["audience"] != "public" || ev["source"] != "event" || ev["creator_id"] != dev || ev["release_version"] != "v1.4.0" ||
		ev["remind_at"] != "" || ev["starts_at"] != "2026-10-06T09:00:00Z" || len(ev["mentions"].([]any)) != 0 {
		t.Fatalf("default audience: %v", ev)
	}
	if bare := calCreate(t, e, tid, dev, calBody("Bare", nil)); bare["kind"] != "other" || bare["audience"] != "public" {
		t.Fatalf("defaults: %v", bare)
	}
	path := "/v1/calendar/events/" + ev["id"].(string)
	// Neither an admin nor the workspace owner may make someone's event private.
	for _, who := range []string{admin, owner, mate} {
		code, out := call(t, e, tid, http.MethodPatch, path, who, map[string]any{"audience": "private"})
		if code != http.StatusForbidden || out["error"] != "private_owner_only" {
			t.Fatalf("non-owner %s sets private: %d %v", who, code, out)
		}
	}
	// CONTROL: anyone who edits moves it between public and internal.
	if code, out := call(t, e, tid, http.MethodPatch, path, admin, map[string]any{"audience": "internal"}); code != http.StatusOK {
		t.Fatalf("admin public -> internal: %d %v", code, out)
	}
	code, out := call(t, e, tid, http.MethodPatch, path, dev, map[string]any{"audience": "private", "mentions": []string{admin, "c-042"}})
	if ev := out["event"].(map[string]any); code != http.StatusOK || ev["audience"] != "private" {
		t.Fatalf("owner sets private: %d %v", code, out)
	}
	// The mentioned admin reads it, but may not take it out of private.
	if code, out := call(t, e, tid, http.MethodPatch, path, admin, map[string]any{"audience": "public"}); code != http.StatusForbidden || out["error"] != "private_owner_only" {
		t.Fatalf("named admin clears private: %d %v", code, out)
	}
	// A member who is not mentioned does not see it, nor reach it.
	if _, out := call(t, e, tid, http.MethodGet, calWeekQuery, mate, nil); calTitles(out, "events") != "Bare" {
		t.Fatalf("not-named member reads: %v", out)
	}
	if code, _ := call(t, e, tid, http.MethodDelete, path, mate, nil); code != http.StatusNotFound {
		t.Fatalf("not-named member deletes a private event: %d", code)
	}
	if _, out := call(t, e, tid, http.MethodGet, calWeekQuery, admin, nil); calTitles(out, "events") != "Bare,Ship" &&
		calTitles(out, "events") != "Ship,Bare" {
		t.Fatalf("named admin reads: %v", out)
	}
	// A create may set private: its caller is the owner.
	if p := calCreate(t, e, tid, mate, calBody("Mine", map[string]any{"audience": "private"})); p["audience"] != "private" {
		t.Fatalf("owner creates private: %v", p)
	}
	if code, out := call(t, e, tid, http.MethodPatch, path, dev, map[string]any{"audience": "public"}); code != http.StatusOK {
		t.Fatalf("owner clears private: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodDelete, path, dev, nil); code != http.StatusOK || out["event"].(map[string]any)["title"] != "Ship" {
		t.Fatalf("delete: %d %v", code, out)
	}
}

func TestCalendarRefusals(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	for _, c := range []struct {
		method, path string
		body         any
		code         int
		token        string
	}{
		{http.MethodGet, "/v1/calendar/events?start=2026-10-05T00:00:00Z", nil, 400, "bad_range"},
		{http.MethodGet, "/v1/calendar/events?start=2026-10-05T00:00:00Z&end=2028-10-05T00:00:00Z", nil, 400, "bad_range"},
		{http.MethodGet, "/v1/calendar/marks?start_year=2020&end_year=2026", nil, 400, "bad_range"},
		{http.MethodGet, "/v1/calendar/reminders?from=2026-10-05T00:00:00Z&to=2026-12-05T00:00:00Z", nil, 400, "bad_range"},
		{http.MethodPost, "/v1/calendar/events", map[string]any{"title": "x", "video_link": "https://example.com"}, 400, "bad_json"},
		{http.MethodPost, "/v1/calendar/events", map[string]any{"title": "x"}, 400, "bad_event"},
		{http.MethodPost, "/v1/calendar/events", calBody("x", map[string]any{"kind": "party"}), 400, "bad_event"},
		{http.MethodPost, "/v1/calendar/events", calBody("x", map[string]any{"audience": "secret"}), 400, "bad_event"},
		{http.MethodPost, "/v1/calendar/events", calBody("x", map[string]any{"ends_at": "2026-10-06T08:00:00Z"}), 400, "bad_event"},
		{http.MethodPatch, "/v1/calendar/events/00000000-0000-4000-8000-000000000000", map[string]any{"title": "y"}, 404, "not_found"},
	} {
		if code, out := call(t, e, tid, c.method, c.path, dev, c.body); code != c.code || out["error"] != c.token {
			t.Errorf("%s %s %v: %d %v, want %d %s", c.method, c.path, c.body, code, out, c.code, c.token)
		}
	}
}

func TestCalendarDemoReadsPublicOnly(t *testing.T) {
	e, demo := demoEnv(t)
	dev, visitor := seat(t, e, demo, rbac.Developer), seat(t, e, demo, rbac.DemoUser)
	pub := calCreate(t, e, demo, dev, calBody("Open", map[string]any{"remind_at": "2026-10-06T08:50:00Z", "mentions": []string{visitor}}))
	calCreate(t, e, demo, dev, calBody("Team", map[string]any{"audience": "internal", "remind_at": "2026-10-06T08:50:00Z", "mentions": []string{visitor}}))
	calCreate(t, e, demo, dev, calBody("Own", map[string]any{"audience": "private"}))

	code, out := call(t, e, demo, http.MethodGet, calWeekQuery, visitor, nil)
	if code != http.StatusOK || calTitles(out, "events") != "Open" {
		t.Fatalf("demo reads: %d %v", code, out)
	}
	code, out = call(t, e, demo, http.MethodGet, "/v1/calendar/reminders?from=2026-10-06T00:00:00Z&to=2026-10-07T00:00:00Z", visitor, nil)
	if code != http.StatusOK || calTitles(out, "reminders") != "Open" {
		t.Fatalf("demo reminders: %d %v", code, out)
	}
	code, out = call(t, e, demo, http.MethodGet, "/v1/calendar/marks?start_year=2025&end_year=2027", visitor, nil)
	if days := out["days"].([]any); code != http.StatusOK || len(days) != 1 || days[0].(map[string]any)["count"] != float64(1) {
		t.Fatalf("demo marks: %d %v", code, out)
	}
	// CONTROL: the developer reads all three.
	if _, out := call(t, e, demo, http.MethodGet, calWeekQuery, dev, nil); len(out["events"].([]any)) != 3 {
		t.Fatalf("developer reads: %v", out)
	}
	path := "/v1/calendar/events/" + pub["id"].(string)
	for _, c := range []struct {
		method, path string
		body         any
	}{
		{http.MethodPost, "/v1/calendar/events", calBody("Demo", nil)},
		{http.MethodPatch, path, map[string]any{"title": "Mine now"}},
		{http.MethodDelete, path, nil},
	} {
		if code, out := call(t, e, demo, c.method, c.path, visitor, c.body); code != http.StatusForbidden || out["error"] != "demo_read_only" {
			t.Fatalf("demo %s: %d %v", c.method, code, out)
		}
	}
}

func TestCalendarRemindersOwnOrMentioned(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	a, b := seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.Developer)
	rem := map[string]any{"remind_at": "2026-10-06T08:45:00Z"}
	calCreate(t, e, tid, a, calBody("A own", rem))
	calCreate(t, e, tid, b, calBody("B names A", map[string]any{"remind_at": "2026-10-06T08:50:00Z", "mentions": []string{a}}))
	calCreate(t, e, tid, b, calBody("B public", rem))
	calCreate(t, e, tid, a, calBody("A quiet", nil))
	q := "/v1/calendar/reminders?from=2026-10-06T00:00:00Z&to=2026-10-07T00:00:00Z"
	if code, out := call(t, e, tid, http.MethodGet, q, a, nil); code != http.StatusOK || calTitles(out, "reminders") != "A own,B names A" ||
		out["from"] != "2026-10-06T00:00:00Z" {
		t.Fatalf("a's reminders: %d %v", code, out)
	}
	if _, out := call(t, e, tid, http.MethodGet, q, b, nil); calTitles(out, "reminders") != "B public,B names A" {
		t.Fatalf("b's reminders: %v", out)
	}
}

func TestCalendarMergesIssueDeadlines(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "Auth", "kind": "epic"}); code != http.StatusCreated {
		t.Fatalf("epic: %d %v", code, out)
	}
	for k, dl := range []string{"2026-10-07T15:00:00Z", "2026-11-20T15:00:00Z"} {
		if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"epic": "SPL-1",
			"title": "Due " + strconv.Itoa(k), "deadline": dl}); code != http.StatusCreated {
			t.Fatalf("issue: %d %v", code, out)
		}
	}
	calCreate(t, e, tid, dev, calBody("Ship", map[string]any{"kind": "release"}))
	_, out := call(t, e, tid, http.MethodGet, calWeekQuery, dev, nil)
	list := out["events"].([]any)
	if calTitles(out, "events") != "Ship,Due 0" {
		t.Fatalf("range with deadlines: %v", out)
	}
	if d := list[1].(map[string]any); d["source"] != "issue" || d["kind"] != "deadline" || d["id"] != "SPL-2" ||
		d["issue_key"] != "SPL-2" || d["starts_at"] != "2026-10-07T15:00:00Z" || d["audience"] != "public" {
		t.Fatalf("deadline item: %v", d)
	}
	_, out = call(t, e, tid, http.MethodGet, "/v1/calendar/marks?start_year=2026&end_year=2026", dev, nil)
	var got []string
	for _, x := range out["days"].([]any) {
		m := x.(map[string]any)
		got = append(got, m["day"].(string)+":"+strings.Join(toStrings(m["kinds"]), "+"))
	}
	if strings.Join(got, " ") != "2026-10-06:release 2026-10-07:deadline 2026-11-20:deadline" ||
		len(out["official_days"].([]any)) != 0 || out["start_year"] != float64(2026) {
		t.Fatalf("marks: %v", out)
	}
}

func toStrings(v any) []string {
	var out []string
	list, _ := v.([]any)
	for _, x := range list {
		out = append(out, x.(string))
	}
	return out
}

// D4: reminders are the WUI's own pop-up. calendar.go (and 097's
// calendar_props.go, the reminders' registry) imports nothing that
// sends (msg, spool, notify, wire) and calls no fan-out or send, and no file
// of the hub package imports internal/notify. CONTROL: the same scan finds
// issues.go's fan-out, so it can see one.
func TestCalendarSendsNothing(t *testing.T) {
	for _, f := range []string{"calendar.go", "calendar_props.go"} {
		if bad := sendersIn(t, f); len(bad) != 0 {
			t.Fatalf("%s reaches a sender: %v", f, bad)
		}
	}
	if got := sendersIn(t, "issues.go"); len(got) == 0 {
		t.Fatal("CONTROL: the scan finds no sender in issues.go")
	}
	files, _ := filepath.Glob("*.go")
	for _, f := range files {
		src, err := os.ReadFile(f)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.HasSuffix(f, "_test.go") && strings.Contains(string(src), "spool-hub-api/internal/notify\"") {
			t.Fatalf("%s imports internal/notify", f)
		}
	}
}

// sendersIn lists the sending imports and calls of one file of the package.
func sendersIn(t *testing.T, name string) []string {
	t.Helper()
	f, err := parser.ParseFile(token.NewFileSet(), name, nil, 0)
	if err != nil {
		t.Fatal(err)
	}
	var out []string
	for _, im := range f.Imports {
		for _, p := range []string{"/internal/msg\"", "/internal/spool\"", "/internal/notify\"", "/internal/wire\""} {
			if strings.HasSuffix(im.Path.Value, p) {
				out = append(out, im.Path.Value)
			}
		}
	}
	ast.Inspect(f, func(n ast.Node) bool {
		if sel, ok := n.(*ast.SelectorExpr); ok {
			if x, ok := sel.X.(*ast.Ident); ok && x.Name == "rbac" {
				return true // a permission name (rbac.NotesSend), not a send
			}
			l := strings.ToLower(sel.Sel.Name)
			if strings.Contains(l, "fanout") || strings.Contains(l, "send") || strings.Contains(l, "notify") || strings.Contains(l, "deliver") {
				out = append(out, sel.Sel.Name)
			}
		}
		return true
	})
	return out
}

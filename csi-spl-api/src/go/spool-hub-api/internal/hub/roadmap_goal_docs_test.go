package hub_test

import (
	"net/http"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/112 HUB-3: in-app goals for a workspace with no repo
// (roadmap_goal_docs.go). A spec 113 workspace doc whose root carries
// attrs.goal is saved by PUT /v1/workspace/doctree/{doc}/goal, which runs
// HUB-2's approval check and upsert for the doc's own workspace. Postgres
// only (the memory store has no doc tree): SPOOL_TEST_PG_DSN,
// PRE_PUSH_TIER=full.
//
//	go test ./internal/hub -run GoalDoc -v

// goalDocEnv is syncEnv on Postgres: the operator token for the HUB-2
// route, and one workspace.
func goalDocEnv(t *testing.T) (*env, string) {
	t.Helper()
	e, tid := syncEnv(t)
	if _, ok := e.st.(*store.Postgres); !ok {
		t.Skip("goal docs are workspace documents, which need Postgres (SPOOL_TEST_PG_DSN)")
	}
	return e, tid
}

// goalDocNew makes a workspace doc in tid as member as.
func goalDocNew(t *testing.T, e *env, tid, as string) string {
	t.Helper()
	return dtStr(mustCall(t, e, tid, http.MethodPost, docTreeAPI, as, map[string]any{"title": "goal"}, 200), "id")
}

// goalOf is a goal doc body: a deadline and the given milestones (each on
// day 2026-11-<nn>), approved by msgID ("" = a draft).
func goalOf(id, msgID string, milestones ...string) map[string]any {
	ms := []map[string]any{}
	for i, k := range milestones {
		ms = append(ms, map[string]any{"key": k, "date": "2026-11-1" + string(rune('0'+i)), "title": k})
	}
	return map[string]any{"id": id, "owner_role": rbac.BizOwner, "deadline": "2026-12-31", "milestones": ms,
		"done_lines": []string{"one measurable line"}, "specs": []string{"112"}, "approval": map[string]any{"msg_id": msgID}}
}

func goalSave(t *testing.T, e *env, tid, as, doc string, goal map[string]any, want int) map[string]any {
	t.Helper()
	return mustCall(t, e, tid, http.MethodPut, docTreeAPI+"/"+doc+"/goal", as, map[string]any{"goal": goal}, want)
}

// TestGoalDocSameEventsAsGoalYAML: an approved goal doc gives the workspace
// the same goal: keys, kinds, days and roadmap link as HUB-2 gives a repo
// workspace from its goal.yaml, written as roadmap-sync; the topic link on
// the root survives the save; a re-save changes nothing.
func TestGoalDocSameEventsAsGoalYAML(t *testing.T) {
	e, app := goalDocEnv(t)
	repo := syncWorkspace(t, e)
	admin := seat(t, e, app, rbac.Admin)
	doc := goalDocNew(t, e, app, admin)
	topic := uuidV4()
	mustCall(t, e, app, http.MethodPut, docTreeAPI+"/"+doc+"/topic", admin, map[string]any{"topic_id": topic}, 200)

	out := goalSave(t, e, app, admin, doc, goalOf("G01-in-app", approvalMsg(t, e, app, admin, ""), "start"), 200)
	if out["approved"] != true || num(out, "created") != 2 {
		t.Fatalf("approved goal doc: %v", out)
	}
	code, rep := syncCall(t, e, repo, []map[string]any{syncGoal(repo, "G01-in-app", approvalMsg(t, e, repo, seat(t, e, repo, rbac.Admin), ""))},
		[]map[string]any{goalEv(repo, "goal:G01:deadline", "goal", "2026-12-31"), goalEv(repo, "goal:G01:m:start", "milestone", "2026-11-10")})
	if code != 200 || num(rep, "created") != 2 {
		t.Fatalf("goal.yaml sync: %d %v", code, rep)
	}
	shape := func(tid string) string {
		return syncedOf(t, e, tid, func(ev store.CalendarEvent) string {
			url, _ := ev.Props["roadmap_url"].(string)
			return ev.SourceKey + "|" + ev.Kind + "|" + ev.StartsAt.Format("2006-01-02") + "|" + ev.CreatorID + "|" + ev.Audience + "|" +
				url[len("/roadmap?ws=")+len(tid):]
		})
	}
	if a, r := shape(app), shape(repo); a != r || a == "" {
		t.Fatalf("in-app goal events differ from goal.yaml ones:\n app  %s\n repo %s", a, r)
	}
	head := mustCall(t, e, app, http.MethodGet, docTreeAPI+"/"+doc, admin, nil, 200)
	if dtStr(head, "topic_id") != topic {
		t.Fatalf("the goal save dropped the root's topic link: %v", head)
	}
	again := goalSave(t, e, app, admin, doc, goalOf("G01-in-app", approvalMsg(t, e, app, admin, ""), "start"), 200)
	if num(again, "created")+num(again, "updated")+num(again, "deleted") != 0 || num(again, "unchanged") != 2 {
		t.Fatalf("a re-save is not idempotent: %v", again)
	}
}

// TestGoalDocUnapprovedWritesNothing (control): a draft, a developer's
// approval, an approval from another workspace and a box's message each
// write no event; withdrawing the approval removes the goal's events.
func TestGoalDocUnapprovedWritesNothing(t *testing.T) {
	e, ws := goalDocEnv(t)
	other := syncWorkspace(t, e)
	admin, dev, owner := seat(t, e, ws, rbac.Admin), seat(t, e, ws, rbac.Developer), seat(t, e, ws, rbac.BizOwner)
	doc := goalDocNew(t, e, ws, dev)
	for name, msgID := range map[string]string{
		"draft":           "",
		"developer":       approvalMsg(t, e, ws, dev, ""),
		"other workspace": approvalMsg(t, e, other, seat(t, e, other, rbac.Admin), ""),
		"a box":           approvalMsg(t, e, ws, admin, "box-a"),
	} {
		out := goalSave(t, e, ws, dev, doc, goalOf("G01-unapproved", msgID, "start"), 200)
		if out["approved"] != false || out["unapproved_reason"] == "" {
			t.Fatalf("%s: saved as approved: %v", name, out)
		}
		if k := liveKeys(t, e, ws); k != "" {
			t.Fatalf("%s: an unapproved goal doc wrote events: %s", name, k)
		}
	}
	goalSave(t, e, ws, dev, doc, goalOf("G01-unapproved", approvalMsg(t, e, ws, owner, ""), "start"), 200)
	if k := liveKeys(t, e, ws); k != "goal:G01:deadline,goal:G01:m:start" {
		t.Fatalf("a biz_owner approval: %q", k)
	}
	out := goalSave(t, e, ws, dev, doc, goalOf("G01-unapproved", "", "start"), 200)
	if k := liveKeys(t, e, ws); k != "" || num(out, "deleted") != 2 {
		t.Fatalf("a withdrawn approval kept events: %q %v", k, out)
	}
}

// TestGoalDocStaysInItsWorkspace (control): a goal doc of workspace B,
// approved there, writes into B only; one naming workspace A is refused
// with nothing written; A's own goals are untouched by B's saves.
func TestGoalDocStaysInItsWorkspace(t *testing.T) {
	e, a := goalDocEnv(t)
	b := syncWorkspace(t, e)
	adminA, adminB := seat(t, e, a, rbac.Admin), seat(t, e, b, rbac.Admin)
	docA, docB := goalDocNew(t, e, a, adminA), goalDocNew(t, e, b, adminB)
	goalSave(t, e, a, adminA, docA, goalOf("G01-in-a", approvalMsg(t, e, a, adminA, "")), 200)

	g := goalOf("G01-in-b", approvalMsg(t, e, b, adminB, ""), "start")
	g["workspace"] = a
	goalSave(t, e, b, adminB, docB, g, 400)
	if ka, kb := liveKeys(t, e, a), liveKeys(t, e, b); ka != "goal:G01:deadline" || kb != "" {
		t.Fatalf("a goal doc of B naming A wrote: A=%q B=%q", ka, kb)
	}
	g["workspace"] = b
	goalSave(t, e, b, adminB, docB, g, 200)
	if ka, kb := liveKeys(t, e, a), liveKeys(t, e, b); ka != "goal:G01:deadline" || kb != "goal:G01:deadline,goal:G01:m:start" {
		t.Fatalf("B's goal doc: A=%q B=%q", ka, kb)
	}
	// a doc of A is not B's: another tenant's doc is 404 (RLS)
	goalSave(t, e, b, adminB, docA, goalOf("G02-cross", approvalMsg(t, e, b, adminB, "")), 404)
}

// TestGoalDocCarriesOtherGoals: a second goal doc keeps the first's events,
// a dropped milestone is soft-deleted, a goal id held by another doc or by a
// goal.yaml is 409, a changed id replaces the doc's old keys, and a stale
// root rev writes nothing.
func TestGoalDocCarriesOtherGoals(t *testing.T) {
	e, ws := goalDocEnv(t)
	admin := seat(t, e, ws, rbac.Admin)
	ok := func() string { return approvalMsg(t, e, ws, admin, "") }
	d1, d2, d3 := goalDocNew(t, e, ws, admin), goalDocNew(t, e, ws, admin), goalDocNew(t, e, ws, admin)
	goalSave(t, e, ws, admin, d1, goalOf("G01-first", ok(), "a", "b"), 200)
	out := goalSave(t, e, ws, admin, d2, goalOf("G02-second", ok()), 200)
	if k := liveKeys(t, e, ws); k != "goal:G01:deadline,goal:G01:m:a,goal:G01:m:b,goal:G02:deadline" || num(out, "carried") != 3 {
		t.Fatalf("a second goal doc pruned the first: %q %v", k, out)
	}
	goalSave(t, e, ws, admin, d1, goalOf("G01-first", ok(), "a"), 200)
	if k := liveKeys(t, e, ws); k != "goal:G01:deadline,goal:G01:m:a,goal:G02:deadline" {
		t.Fatalf("a dropped milestone stayed: %q", k)
	}
	goalSave(t, e, ws, admin, d3, goalOf("G02-copy", ok()), 409)
	goalSave(t, e, ws, admin, d2, goalOf("G03-renamed", ok()), 200)
	if k := liveKeys(t, e, ws); k != "goal:G01:deadline,goal:G01:m:a,goal:G03:deadline" {
		t.Fatalf("a renamed goal kept its old keys: %q", k)
	}
	before := liveKeys(t, e, ws)
	mustCall(t, e, ws, http.MethodPut, docTreeAPI+"/"+d1+"/goal", admin, map[string]any{"rev": 999, "goal": goalOf("G01-first", "")}, 412)
	if k := liveKeys(t, e, ws); k != before {
		t.Fatalf("a stale save wrote events: %q", k)
	}
	// a goal id a goal.yaml holds (HUB-2's deploy sync) is 409 in-app
	repo := syncWorkspace(t, e)
	ra := seat(t, e, repo, rbac.Admin)
	code, _ := syncCall(t, e, repo, []map[string]any{syncGoal(repo, "G05-from-yaml", approvalMsg(t, e, repo, ra, ""))},
		[]map[string]any{goalEv(repo, "goal:G05:deadline", "goal", "2026-12-31")})
	if code != 200 {
		t.Fatalf("goal.yaml sync: %d", code)
	}
	goalSave(t, e, repo, ra, goalDocNew(t, e, repo, ra), goalOf("G05-in-app", approvalMsg(t, e, repo, ra, "")), 409)
	if k := liveKeys(t, e, repo); k != "goal:G05:deadline" {
		t.Fatalf("a refused in-app goal touched the goal.yaml one: %q", k)
	}
}

// TestGoalDocRefusals: a goal field off spec 2's rules is 400.
func TestGoalDocRefusals(t *testing.T) {
	e, ws := goalDocEnv(t)
	admin := seat(t, e, ws, rbac.Admin)
	doc := goalDocNew(t, e, ws, admin)
	for name, mut := range map[string]func(map[string]any){
		"id":        func(g map[string]any) { g["id"] = "goal-1" },
		"deadline":  func(g map[string]any) { g["deadline"] = "31.12.2026" },
		"role":      func(g map[string]any) { g["owner_role"] = "FirstName LastName" },
		"spec":      func(g map[string]any) { g["specs"] = []string{"1120"} },
		"milestone": func(g map[string]any) { g["milestones"] = []map[string]any{{"key": "A B", "date": "2026-11-01"}} },
	} {
		g := goalOf("G01-ok", "")
		mut(g)
		if code, out := call(t, e, ws, http.MethodPut, docTreeAPI+"/"+doc+"/goal", admin, map[string]any{"goal": g}); code != 400 {
			t.Fatalf("%s: %d %v, want 400", name, code, out)
		}
	}
}

// goalEv is one HUB-2 wire event as ORC-2 builds it from a goal.yaml.
func goalEv(ws, key, kind, day string) map[string]any {
	ev := syncEv(ws, key, day)
	ev["kind"] = kind
	ev["roadmap_url"] = "/roadmap?ws=" + ws + "&goal=" + goalOfTestKey(key)
	return ev
}

func goalOfTestKey(k string) string { return k[len("goal:") : len("goal:")+3] }

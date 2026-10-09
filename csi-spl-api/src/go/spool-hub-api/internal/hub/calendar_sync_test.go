package hub_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// specs/112 HUB-1, HUB-2: PUT /v1/calendar/sync. The deploy identity alone
// writes (an agent token and a member session are 403); each goal and event
// names its workspace, and the same key in two workspaces is two rows; a goal
// is published only on an approval message of a biz_owner or an admin of the
// goal's own workspace (12.3); a roadmap event carries no audience and is
// written internal, or public when its workspace's switch is on (12.5); a
// partial batch never soft-deletes the goals (the STORE-1 finding: this route
// prunes only the key families it carries, per workspace); a synced event is
// 409 to PATCH and DELETE and found by ?source_key=. Memory, and Postgres
// under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

const syncPath = "/v1/calendar/sync"

// syncEnv is a hub whose operator token is "good", and one fresh workspace.
func syncEnv(t *testing.T) (*env, string) {
	t.Helper()
	e := rbacEnv(t, func(o *hub.Options) {
		o.OperatorEmails = []string{operatorSA}
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			switch token {
			case "good":
				return operatorSA, nil
			case "other-sa":
				return "intruder@example-dev.iam.gserviceaccount.com", nil
			}
			return "", errors.New("token rejected")
		}
	})
	return e, syncWorkspace(t, e)
}

// syncWorkspace adds one more fresh workspace to e.
func syncWorkspace(t *testing.T, e *env) string {
	t.Helper()
	b := make([]byte, 4)
	rand.Read(b) //nolint:errcheck
	tid := "rm" + hex.EncodeToString(b)
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: tid, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	return tid
}

// approvalMsg stores a message of tid written by from in a member session
// (box-wui, unsigned), or by a box when box is set.
func approvalMsg(t *testing.T, e *env, tid, from, box string) string {
	t.Helper()
	id, at := uuidV4(), time.Now().UTC().Truncate(time.Microsecond)
	m := store.Message{TenantID: tid, MsgID: id, TaskID: uuidV4(), IsParent: 1, TS: at, FromBox: hub.WUIBox, FromID: from,
		ToBox: hub.WUIBox, ToID: "ALL-0", Kind: "note", Body: "approved", Files: []byte(`[]`), Msg: []byte(`{"v":1}`),
		Env: []byte(`{"id":"` + id + `"}`), ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
	if box != "" {
		m.FromBox, m.EnvSig = box, "sig"
	}
	if _, err := e.st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
	return id
}

func syncGoal(ws, id, msgID string) map[string]any {
	return map[string]any{"id": id, "workspace": ws, "approval": map[string]any{"msg_id": msgID}}
}

// syncEv is one wire event of workspace ws, with no audience.
func syncEv(ws, key, day string) map[string]any {
	kind := "goal"
	switch {
	case strings.HasPrefix(key, "spec:"), strings.HasPrefix(key, "db:"):
		kind = "milestone"
	case strings.HasPrefix(key, "release:"):
		kind = "release"
	}
	return map[string]any{"source_key": key, "workspace": ws, "title": key, "kind": kind, "starts_at": day + "T00:00:00Z",
		"ends_at": day + "T00:00:00Z", "all_day": true, "roadmap_url": "/roadmap?goal=G01"}
}

func syncCall(t *testing.T, e *env, tid string, goals, events []map[string]any) (int, map[string]any) {
	t.Helper()
	if goals == nil {
		goals = []map[string]any{}
	}
	return opCall(t, e, tid, http.MethodPut, syncPath, "good", map[string]any{"goals": goals, "events": events})
}

// liveKeys lists tid's live synced keys, read through the store.
func liveKeys(t *testing.T, e *env, tid string) string {
	t.Helper()
	return syncedOf(t, e, tid, func(ev store.CalendarEvent) string { return ev.SourceKey })
}

// liveAudiences lists tid's live synced keys with their audience.
func liveAudiences(t *testing.T, e *env, tid string) string {
	t.Helper()
	return syncedOf(t, e, tid, func(ev store.CalendarEvent) string { return ev.SourceKey + "=" + ev.Audience })
}

func syncedOf(t *testing.T, e *env, tid string, f func(store.CalendarEvent) string) string {
	t.Helper()
	evs, err := e.st.(store.CalendarSourced).CalendarBySourceKey(context.Background(), tid, "", "")
	if err != nil {
		t.Fatal(err)
	}
	var ks []string
	for _, ev := range evs {
		ks = append(ks, f(ev))
	}
	sort.Strings(ks)
	return strings.Join(ks, ",")
}

func num(out map[string]any, k string) int {
	f, _ := out[k].(float64)
	return int(f)
}

func TestCalendarSyncDeployIdentityOnly(t *testing.T) {
	e, tid := syncEnv(t)
	admin, dev := seat(t, e, tid, rbac.Admin), seat(t, e, tid, rbac.Developer)
	b := e.box(tid, "box-a", "c-001")
	e.pin(tid, b)
	agent := e.uploadToken(tid, b)
	body := map[string]any{"goals": []any{}, "events": []any{syncEv(tid, "release:v1.3.0", "2026-10-01")}}

	// CONTROL: an agent token is 403, though a bearer
	if code, out := opCall(t, e, tid, http.MethodPut, syncPath, agent, body); code != http.StatusForbidden || out["error"] != "deploy_identity_only" {
		t.Fatalf("agent token: %d %v", code, out)
	}
	// a member session, a biz_owner's or an admin's included, is 403
	for _, who := range []string{admin, dev} {
		if code, out := call(t, e, tid, http.MethodPut, syncPath, who, body); code != http.StatusForbidden || out["error"] != "deploy_identity_only" {
			t.Fatalf("member %s: %d %v", who, code, out)
		}
	}
	if code, _ := opCall(t, e, tid, http.MethodPut, syncPath, "", body); code != http.StatusUnauthorized {
		t.Fatalf("no token: %d", code)
	}
	if code, out := opCall(t, e, tid, http.MethodPut, syncPath, "other-sa", body); code != http.StatusForbidden || out["error"] != "not_operator" {
		t.Fatalf("another SA: %d %v", code, out)
	}
	if got := liveKeys(t, e, tid); got != "" {
		t.Fatalf("a refused call wrote %q", got)
	}
	// the deploy identity writes, as roadmap-sync
	code, out := opCall(t, e, tid, http.MethodPut, syncPath, "good", body)
	if ws, _ := out["workspaces"].(map[string]any); code != http.StatusOK || num(out, "created") != 1 || num(ws[tid].(map[string]any), "created") != 1 {
		t.Fatalf("deploy identity: %d %v", code, out)
	}
	_, list := call(t, e, tid, http.MethodGet, "/v1/calendar/events?source_key=release:", dev, nil)
	evs, _ := list["events"].([]any)
	if len(evs) != 1 {
		t.Fatalf("release listed: %v", list)
	}
	ev := evs[0].(map[string]any)
	if ev["creator_type"] != "system" || ev["creator_id"] != "roadmap-sync" || ev["source_key"] != "release:v1.3.0" ||
		ev["roadmap_url"] != "/roadmap?goal=G01" || ev["audience"] != store.CalendarInternal {
		t.Fatalf("synced event: %v", ev)
	}
}

func TestCalendarSyncApproval(t *testing.T) {
	e, tid := syncEnv(t)
	owner, admin := seat(t, e, tid, rbac.BizOwner), seat(t, e, tid, rbac.Admin)
	dev, user := seat(t, e, tid, rbac.Developer), seat(t, e, tid, rbac.RegularUser)
	other := syncWorkspace(t, e)
	elsewhere := seat(t, e, other, rbac.Admin)
	goals := []map[string]any{
		// a biz_owner approval and an admin approval each write the goal (12.3)
		syncGoal(tid, "G01-owner", approvalMsg(t, e, tid, owner, "")),
		syncGoal(tid, "G02-admin", approvalMsg(t, e, tid, admin, "")),
		// CONTROL: a member's approval writes nothing, whatever their role
		syncGoal(tid, "G03-developer", approvalMsg(t, e, tid, dev, "")),
		syncGoal(tid, "G04-user", approvalMsg(t, e, tid, user, "")),
		syncGoal(tid, "G05-draft", ""),
		syncGoal(tid, "G06-boxed", approvalMsg(t, e, tid, admin, "box-a")),
		// CONTROL: an admin of another workspace approves nothing here, by a
		// message there or by one here
		syncGoal(tid, "G07-elsewhere", approvalMsg(t, e, other, elsewhere, "")),
		syncGoal(tid, "G08-stranger", approvalMsg(t, e, tid, elsewhere, "")),
		syncGoal(tid, "G09-short", "5a9aab48"),
	}
	var events []map[string]any
	for _, g := range goals {
		events = append(events, syncEv(tid, "goal:"+g["id"].(string)[:3]+":deadline", "2026-12-31"))
	}
	code, out := syncCall(t, e, tid, goals, events)
	if code != http.StatusOK || num(out, "created") != 2 {
		t.Fatalf("sync: %d %v", code, out)
	}
	if got := liveKeys(t, e, tid); got != "goal:G01:deadline,goal:G02:deadline" {
		t.Fatalf("written: %q", got)
	}
	un, _ := out["unapproved"].([]any)
	var ids []string
	for _, u := range un {
		m := u.(map[string]any)
		if m["reason"] == "" || m["workspace"] != tid {
			t.Fatalf("no reason or workspace: %v", m)
		}
		ids = append(ids, m["id"].(string))
	}
	if strings.Join(ids, ",") != "G03-developer,G04-user,G05-draft,G06-boxed,G07-elsewhere,G08-stranger,G09-short" {
		t.Fatalf("unapproved: %v", un)
	}
	if got := liveKeys(t, e, other); got != "" {
		t.Fatalf("the other workspace got %q", got)
	}
	// a goal: key that names no goal of its workspace is refused whole, a
	// goal of another workspace included
	if code, out := syncCall(t, e, tid, goals[:1], events[:2]); code != http.StatusBadRequest || out["error"] != "bad_event" {
		t.Fatalf("unknown goal key: %d %v", code, out)
	}
	cross := []map[string]any{syncGoal(other, "G01-owner", approvalMsg(t, e, other, elsewhere, ""))}
	if code, out := syncCall(t, e, tid, cross, events[:1]); code != http.StatusBadRequest || out["error"] != "bad_event" {
		t.Fatalf("goal of another workspace: %d %v", code, out)
	}
}

// TestCalendarSyncTwoWorkspaces (12.4): one request, two workspaces; the same
// goal key is a row in each, and a request naming one leaves the other alone.
func TestCalendarSyncTwoWorkspaces(t *testing.T) {
	e, a := syncEnv(t)
	b := syncWorkspace(t, e)
	adminA, ownerB := seat(t, e, a, rbac.Admin), seat(t, e, b, rbac.BizOwner)
	goals := []map[string]any{syncGoal(a, "G01-alpha", approvalMsg(t, e, a, adminA, "")),
		syncGoal(b, "G01-beta", approvalMsg(t, e, b, ownerB, "")),
		// CONTROL: an admin of a approving a goal of b writes nothing, though
		// a is in the same request
		syncGoal(b, "G02-crossed", approvalMsg(t, e, a, adminA, ""))}
	events := []map[string]any{syncEv(a, "goal:G01:deadline", "2026-12-31"), syncEv(b, "goal:G01:deadline", "2027-03-31"),
		syncEv(b, "spec:089:done", "2026-10-02"), syncEv(b, "goal:G02:deadline", "2027-01-31")}
	code, out := syncCall(t, e, a, goals, events)
	if un, _ := out["unapproved"].([]any); code != http.StatusOK || num(out, "created") != 3 || len(un) != 1 {
		t.Fatalf("sync: %d %v", code, out)
	}
	// CONTROL: two rows, never one
	if ka, kb := liveKeys(t, e, a), liveKeys(t, e, b); ka != "goal:G01:deadline" || kb != "goal:G01:deadline,spec:089:done" {
		t.Fatalf("a=%q b=%q", ka, kb)
	}
	evA, _ := e.st.(store.CalendarSourced).CalendarBySourceKey(context.Background(), a, "", "goal:G01:")
	evB, _ := e.st.(store.CalendarSourced).CalendarBySourceKey(context.Background(), b, "", "goal:G01:")
	if len(evA) != 1 || len(evB) != 1 || evA[0].ID == evB[0].ID || evA[0].StartsAt.Equal(evB[0].StartsAt) {
		t.Fatalf("one row for two workspaces: %+v %+v", evA, evB)
	}
	// a's goals again, alone: b is not touched (nothing pruned there)
	code, out = syncCall(t, e, a, goals[:1], events[:1])
	if code != http.StatusOK || num(out, "unchanged") != 1 || num(out, "deleted") != 0 || liveKeys(t, e, b) != "goal:G01:deadline,spec:089:done" {
		t.Fatalf("a alone: %d %v b=%q", code, out, liveKeys(t, e, b))
	}
	// a workspace that does not exist, or none named, refuses the whole request
	for _, ws := range []string{"rmnosuch1", ""} {
		bad := append([]map[string]any{syncEv(a, "release:v9.0.0", "2026-10-01")}, syncEv(ws, "release:v9.0.1", "2026-10-01"))
		if code, out := syncCall(t, e, a, nil, bad); code != http.StatusBadRequest || out["error"] != "bad_event" {
			t.Fatalf("workspace %q: %d %v", ws, code, out)
		}
	}
	if got := liveKeys(t, e, a); got != "goal:G01:deadline" {
		t.Fatalf("a refused request wrote: %q", got)
	}
}

// TestCalendarSyncAudience (12.5, 4.3): a roadmap event names no audience and
// follows its workspace's switch; db: stays internal.
func TestCalendarSyncAudience(t *testing.T) {
	e, tid := syncEnv(t)
	owner := seat(t, e, tid, rbac.BizOwner)
	goals := []map[string]any{syncGoal(tid, "G01-first", approvalMsg(t, e, tid, owner, ""))}
	db := syncEv(tid, "db:t-0001", "2026-09-20")
	events := []map[string]any{syncEv(tid, "goal:G01:deadline", "2026-12-31"), syncEv(tid, "release:v1.3.0", "2026-10-01"), db}
	// CONTROL: an audience on a roadmap event is refused, workspace or not
	for _, aud := range []string{store.CalendarWorkspace, store.CalendarInternal, store.CalendarPublic, "web"} {
		ev := syncEv(tid, "goal:G01:deadline", "2026-12-31")
		ev["audience"] = aud
		if code, out := syncCall(t, e, tid, goals, []map[string]any{ev}); code != http.StatusBadRequest || out["error"] != "bad_event" {
			t.Fatalf("audience %s: %d %v", aud, code, out)
		}
	}
	dbOpen := syncEv(tid, "db:t-0002", "2026-09-21")
	dbOpen["audience"] = store.CalendarWorkspace
	if code, out := syncCall(t, e, tid, nil, []map[string]any{dbOpen}); code != http.StatusBadRequest {
		t.Fatalf("db: workspace: %d %v", code, out)
	}
	if got := liveKeys(t, e, tid); got != "" {
		t.Fatalf("a refused audience wrote %q", got)
	}
	db["audience"] = store.CalendarInternal // a db: event may say internal
	if code, out := syncCall(t, e, tid, goals, events); code != http.StatusOK || num(out, "created") != 3 {
		t.Fatalf("sync: %d %v", code, out)
	}
	internal := "db:t-0001=internal,goal:G01:deadline=internal,release:v1.3.0=internal"
	if got := liveAudiences(t, e, tid); got != internal {
		t.Fatalf("internal by default: %q", got)
	}
	// the switch re-audiences at once, and the next sync writes the same
	if code, out := call(t, e, tid, http.MethodPatch, "/v1/workspaces/"+tid+"/roadmap", owner, map[string]any{"public": true}); code != http.StatusOK || out["public"] != true {
		t.Fatalf("switch: %d %v", code, out)
	}
	public := "db:t-0001=internal,goal:G01:deadline=" + store.CalendarPublic + ",release:v1.3.0=" + store.CalendarPublic
	if got := liveAudiences(t, e, tid); got != public {
		t.Fatalf("after the switch: %q", got)
	}
	if code, out := syncCall(t, e, tid, goals, events); code != http.StatusOK || num(out, "unchanged") != 3 || liveAudiences(t, e, tid) != public {
		t.Fatalf("sync after the switch: %d %v %q", code, out, liveAudiences(t, e, tid))
	}
	delete(db, "audience") // or say nothing
	if code, out := syncCall(t, e, tid, goals, events); code != http.StatusOK || num(out, "unchanged") != 3 {
		t.Fatalf("db: no audience: %d %v", code, out)
	}
}

func TestCalendarSyncPartialBatchKeepsGoals(t *testing.T) {
	e, tid := syncEnv(t)
	admin := seat(t, e, tid, rbac.Admin)
	goals := []map[string]any{syncGoal(tid, "G01-first", approvalMsg(t, e, tid, admin, ""))}
	full := []map[string]any{syncEv(tid, "goal:G01:deadline", "2026-12-31"), syncEv(tid, "goal:G01:m:start", "2026-09-17"),
		syncEv(tid, "spec:089:done", "2026-10-02")}
	if code, out := syncCall(t, e, tid, goals, full); code != http.StatusOK || num(out, "created") != 3 {
		t.Fatalf("full: %d %v", code, out)
	}
	// the same batch again changes nothing
	if code, out := syncCall(t, e, tid, goals, full); code != http.StatusOK || num(out, "unchanged") != 3 || num(out, "created") != 0 {
		t.Fatalf("re-run: %d %v", code, out)
	}
	// CONTROL (finding 1): the 8.1 backfill's release: keys alone delete nothing
	code, out := syncCall(t, e, tid, nil, []map[string]any{syncEv(tid, "release:v1.3.0", "2026-10-01")})
	if code != http.StatusOK || num(out, "deleted") != 0 || num(out, "carried") != 3 || num(out, "created") != 1 {
		t.Fatalf("partial: %d %v", code, out)
	}
	if got := liveKeys(t, e, tid); got != "goal:G01:deadline,goal:G01:m:start,release:v1.3.0,spec:089:done" {
		t.Fatalf("after partial: %q", got)
	}
	// a batch that carries the goal family carries it whole: a dropped
	// milestone goes, the spec: family it does not carry stays
	code, out = syncCall(t, e, tid, goals, full[:1])
	if code != http.StatusOK || num(out, "deleted") != 1 || num(out, "carried") != 1 {
		t.Fatalf("goal family: %d %v", code, out)
	}
	if got := liveKeys(t, e, tid); got != "goal:G01:deadline,release:v1.3.0,spec:089:done" {
		t.Fatalf("after goal family: %q", got)
	}
	// a goal that turns unapproved loses its events though goals[] names it
	code, out = syncCall(t, e, tid, []map[string]any{syncGoal(tid, "G01-first", "")}, full[:1])
	if code != http.StatusOK || num(out, "deleted") != 1 || liveKeys(t, e, tid) != "release:v1.3.0,spec:089:done" {
		t.Fatalf("unapproved: %d %v %q", code, out, liveKeys(t, e, tid))
	}
}

func TestCalendarSyncedReadOnlyAndLookup(t *testing.T) {
	e, tid := syncEnv(t)
	admin := seat(t, e, tid, rbac.Admin)
	goals := []map[string]any{syncGoal(tid, "G01-first", approvalMsg(t, e, tid, admin, "")),
		syncGoal(tid, "G11-eleventh", approvalMsg(t, e, tid, admin, ""))}
	events := []map[string]any{syncEv(tid, "goal:G01:deadline", "2026-12-31"), syncEv(tid, "goal:G01:m:start", "2026-09-17"),
		syncEv(tid, "goal:G11:deadline", "2027-06-30")}
	if code, out := syncCall(t, e, tid, goals, events); code != http.StatusOK || num(out, "created") != 3 {
		t.Fatalf("sync: %d %v", code, out)
	}
	_, out := call(t, e, tid, http.MethodGet, "/v1/calendar/events?source_key=goal:G01:", admin, nil)
	evs, _ := out["events"].([]any)
	var keys []string
	for _, x := range evs {
		keys = append(keys, x.(map[string]any)["source_key"].(string))
	}
	if strings.Join(keys, ",") != "goal:G01:m:start,goal:G01:deadline" {
		t.Fatalf("?source_key=goal:G01: %v", out)
	}
	if code, out := call(t, e, tid, http.MethodGet, "/v1/calendar/events?source_key=goal:G01:&start=2026-12-01T00:00:00Z&end=2027-01-01T00:00:00Z", admin, nil); code != http.StatusOK || len(out["events"].([]any)) != 1 {
		t.Fatalf("source_key in a range: %d %v", code, out)
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/calendar/events?source_key=nope", admin, nil); code != http.StatusBadRequest {
		t.Fatalf("bad prefix: %d", code)
	}
	path := "/v1/calendar/events/" + evs[0].(map[string]any)["id"].(string)
	if code, out := call(t, e, tid, http.MethodPatch, path, admin, map[string]any{"title": "moved"}); code != http.StatusConflict || out["error"] != "synced_read_only" {
		t.Fatalf("PATCH synced: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodDelete, path, admin, nil); code != http.StatusConflict || out["error"] != "synced_read_only" {
		t.Fatalf("DELETE synced: %d %v", code, out)
	}
	// CONTROL: a member's own event is changed and deleted as before
	own := "/v1/calendar/events/" + calCreate(t, e, tid, admin, calBody("Mine", nil))["id"].(string)
	if code, out := call(t, e, tid, http.MethodPatch, own, admin, map[string]any{"title": "moved"}); code != http.StatusOK {
		t.Fatalf("PATCH own: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodDelete, own, admin, nil); code != http.StatusOK {
		t.Fatalf("DELETE own: %d %v", code, out)
	}
	if got := liveKeys(t, e, tid); got != "goal:G01:deadline,goal:G01:m:start,goal:G11:deadline" {
		t.Fatalf("synced after the refusals: %q", got)
	}
}

// ORC-2 sends a deadline event's goal specs and done lines as top-level wire
// fields (specs/112); the sync keeps them in the event's props.
func TestCalendarSyncSpecsAndDoneLines(t *testing.T) {
	e, tid := syncEnv(t)
	admin := seat(t, e, tid, rbac.Admin)
	ev := syncEv(tid, "goal:G01:deadline", "2026-12-31")
	ev["specs"] = []string{"089", "112"}
	ev["done_lines"] = []string{"100% of specs are [x]"}
	plain := syncEv(tid, "goal:G01:m:start", "2026-11-01")
	goals := []map[string]any{syncGoal(tid, "G01-first", approvalMsg(t, e, tid, admin, ""))}
	if code, out := syncCall(t, e, tid, goals, []map[string]any{ev, plain}); code != http.StatusOK || num(out, "created") != 2 {
		t.Fatalf("sync: %d %v", code, out)
	}
	props := func(ev store.CalendarEvent) string {
		b, _ := json.Marshal([]any{ev.Props["specs"], ev.Props["done_lines"]})
		return ev.SourceKey + "=" + string(b)
	}
	want := `goal:G01:deadline=[["089","112"],["100% of specs are [x]"]],goal:G01:m:start=[null,null]`
	if got := syncedOf(t, e, tid, props); got != want {
		t.Fatalf("props:\n got %s\nwant %s", got, want)
	}
	// CONTROL: a spec that is not a three-digit id, or a blank done line, is 400
	for k, v := range map[string]any{"specs": []string{"G01"}, "done_lines": []string{" "}} {
		bad := syncEv(tid, "goal:G01:deadline", "2026-12-31")
		bad[k] = v
		if code, out := syncCall(t, e, tid, goals, []map[string]any{bad, plain}); code != http.StatusBadRequest {
			t.Fatalf("bad %s: %d %v", k, code, out)
		}
	}
	if got := syncedOf(t, e, tid, props); got != want {
		t.Fatalf("a refused call changed props: %s", got)
	}
}

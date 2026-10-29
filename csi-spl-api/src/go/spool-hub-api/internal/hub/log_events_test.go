package hub_test

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 162 row B3 (SPL-4167): the Workspace and System logs over HTTP,
// GET/POST /v1/view/events and /v1/operator/events. Memory, and Postgres
// under SPOOL_TEST_PG_DSN (rdb 0240's RLS). Each case names its spec 4 row.
// RED CONTROL (master): the routes did not exist, every call answered 404.

const (
	wsEventsPath  = "/v1/view/events"
	sysEventsPath = "/v1/operator/events"
)

type logPage struct {
	Events []struct {
		ID         int64     `json:"id"`
		At         time.Time `json:"at"`
		Kind       string    `json:"kind"`
		Level      string    `json:"level"`
		Actor      string    `json:"actor"`
		Message    string    `json:"message"`
		OriginKind string    `json:"origin_kind"`
		OriginRef  string    `json:"origin_ref"`
	} `json:"events"`
	NextBefore int64 `json:"next_before"`
}

// readLog is GET path in tid as hum, decoded; the code is checked.
func readLog(t *testing.T, e *env, tid, path, hum string, want int) (logPage, map[string]any) {
	t.Helper()
	code, body := call(t, e, tid, http.MethodGet, path, hum, nil)
	if code != want {
		t.Fatalf("GET %s in %s as %s: %d %v, want %d", path, tid, hum, code, body, want)
	}
	raw, _ := json.Marshal(body)
	var p logPage
	if err := json.Unmarshal(raw, &p); err != nil {
		t.Fatal(err)
	}
	return p, body
}

// addWS writes one workspace row of tid through the store.
func addWS(t *testing.T, e *env, tid, msg string) store.LogEvent {
	t.Helper()
	ev, err := e.st.(store.LogEvents).AddWorkspaceEvent(context.Background(), tid, store.LogEvent{Kind: store.LogKindMemberInvited,
		Actor: "HUM-1", Message: msg, OriginKind: store.LogOriginComponent, OriginRef: "members"}, time.Now().UTC())
	if err != nil {
		t.Fatal(err)
	}
	return ev
}

// C12: the workspace's owner and admin read its log, every other role and
// the anonymous door-off guest get 403 workspace.events; another
// workspace's admin reads its own log, none of this one's rows. Paging by
// next_before.
func TestWorkspaceEventsRead(t *testing.T) {
	e, op, other, who, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	var mine []store.LogEvent
	for i := 0; i < 3; i++ {
		mine = append(mine, addWS(t, e, other, fmt.Sprintf("other %d", i)))
	}
	theirs := addWS(t, e, op, "op only")
	for _, role := range rbac.RoleIDs {
		want := http.StatusForbidden
		if role == rbac.Admin || role == rbac.BizOwner {
			want = http.StatusOK
		}
		p, body := readLog(t, e, other, wsEventsPath, whoOther[role], want)
		if want == http.StatusForbidden {
			if body["permission"] != "workspace.events" {
				t.Errorf("C12 %s: %v, want permission workspace.events", role, body)
			}
			continue
		}
		if len(p.Events) != 3 || p.Events[0].ID != mine[2].ID || p.NextBefore != 0 {
			t.Errorf("C12 %s reads %+v, want its 3 rows newest first", role, p)
		}
	}
	if _, body := readLog(t, e, other, wsEventsPath, "", http.StatusForbidden); body["permission"] != "workspace.events" {
		t.Errorf("C12 anonymous: %v", body)
	}
	p, _ := readLog(t, e, op, wsEventsPath, who[rbac.Admin], http.StatusOK)
	if len(p.Events) != 1 || p.Events[0].ID != theirs.ID {
		t.Errorf("C12 another workspace's admin reads %+v, want only its own row", p)
	}
	r0 := p.Events[0]
	if r0.Kind != store.LogKindMemberInvited || r0.Level != "info" || r0.Actor != "HUM-1" || r0.Message != "op only" ||
		r0.OriginKind != "component" || r0.OriginRef != "members" || r0.At.IsZero() {
		t.Errorf("row shape: %+v", r0)
	}
	p, _ = readLog(t, e, other, wsEventsPath+"?limit=2", whoOther[rbac.Admin], http.StatusOK)
	if len(p.Events) != 2 || p.NextBefore != mine[1].ID {
		t.Fatalf("page 1: %+v", p)
	}
	p, _ = readLog(t, e, other, fmt.Sprintf("%s?limit=2&before=%d", wsEventsPath, p.NextBefore), whoOther[rbac.Admin], http.StatusOK)
	if len(p.Events) != 1 || p.Events[0].ID != mine[0].ID || p.NextBefore != 0 {
		t.Fatalf("page 2: %+v", p)
	}
	for _, q := range []string{"?limit=0", "?limit=x", "?before=0", "?before=-1"} {
		if code, _ := call(t, e, other, http.MethodGet, wsEventsPath+q, whoOther[rbac.Admin], nil); code != http.StatusBadRequest {
			t.Errorf("%s: %d, want 400", q, code)
		}
	}
}

// C14 (Workspace): delete selected removes the named rows of this
// workspace only (another workspace's id counts 0) and writes one
// log.deleted row, actor the caller, "2 rows deleted"; a member may not
// delete; a bad body is 400 and deletes nothing.
func TestWorkspaceEventsDelete(t *testing.T) {
	e, op, other, _, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	keep, a, b := addWS(t, e, other, "keep"), addWS(t, e, other, "a"), addWS(t, e, other, "b")
	theirs := addWS(t, e, op, "op only")
	del := wsEventsPath + "/delete"
	for _, bad := range []any{map[string]any{}, map[string]any{"ids": []int64{}}, map[string]any{"ids": make([]int64, 201)},
		map[string]any{"ids": []any{"x"}}, map[string]any{"ids": []any{1.5}}, map[string]any{"ids": []int64{-1}},
		map[string]any{"ids": []int64{a.ID}, "all": true}} {
		if code, body := call(t, e, other, http.MethodPost, del, whoOther[rbac.Admin], bad); code != http.StatusBadRequest {
			t.Errorf("body %v: %d %v, want 400", bad, code, body)
		}
	}
	if code, body := call(t, e, other, http.MethodPost, del, whoOther[rbac.Developer], map[string]any{"ids": []int64{a.ID}}); code != http.StatusForbidden || body["permission"] != "workspace.events" {
		t.Errorf("a developer's delete: %d %v, want 403 workspace.events", code, body)
	}
	code, body := call(t, e, other, http.MethodPost, del, whoOther[rbac.BizOwner], map[string]any{"ids": []int64{a.ID, b.ID, theirs.ID}})
	if code != http.StatusOK || body["deleted"] != float64(2) {
		t.Fatalf("C14 delete: %d %v, want 200 deleted 2", code, body)
	}
	p, _ := readLog(t, e, other, wsEventsPath, whoOther[rbac.Admin], http.StatusOK)
	if len(p.Events) != 2 || p.Events[1].ID != keep.ID || p.Events[0].Kind != store.LogKindDeleted ||
		p.Events[0].Actor != whoOther[rbac.BizOwner] || p.Events[0].Message != "2 rows deleted" {
		t.Fatalf("C14 after delete: %+v", p)
	}
	if code, body := call(t, e, other, http.MethodPost, del, whoOther[rbac.Admin], map[string]any{"ids": []int64{a.ID}}); code != http.StatusOK || body["deleted"] != float64(0) {
		t.Fatalf("delete again: %d %v", code, body)
	}
	if p, _ := readLog(t, e, other, wsEventsPath, whoOther[rbac.Admin], http.StatusOK); len(p.Events) != 2 {
		t.Fatalf("a delete of nothing left a trace: %+v", p)
	}
	if code, body := call(t, e, other, http.MethodPost, del, whoOther[rbac.Admin], map[string]any{"ids": []int64{theirs.ID}}); code != http.StatusOK || body["deleted"] != float64(0) {
		t.Fatalf("another workspace's id: %d %v, want deleted 0", code, body)
	}
	if p, _ := readLog(t, e, op, wsEventsPath, "", http.StatusForbidden); len(p.Events) != 0 {
		t.Fatal("anonymous read rows")
	}
	if ev, _ := e.st.(store.LogEvents).WorkspaceEventsPage(context.Background(), op, 0, 10); len(ev) != 1 || ev[0].ID != theirs.ID {
		t.Fatalf("CONTROL: the operator workspace's row: %+v", ev)
	}
}

// C13 + C14 (System): only the operator workspace's admin reads and deletes
// the system log; its biz_owner and every other role, another workspace's
// admin and the anonymous guest get 403 operator.workspaces. A delete
// leaves one log.deleted row by the caller.
func TestSystemEvents(t *testing.T) {
	e, op, other, who, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	es := e.st.(store.LogEvents)
	now := time.Now().UTC()
	var ids []int64
	for _, k := range []string{store.LogKindHubStarted, store.LogKindLeaseFailover, store.LogKindLeaseRotation} {
		ev, err := es.AddSystemEvent(context.Background(), store.LogEvent{Kind: k, Actor: "hub", Message: "b3 " + op}, now)
		if err != nil {
			t.Fatal(err)
		}
		ids = append(ids, ev.ID)
	}
	del := sysEventsPath + "/delete"
	type caller struct{ name, tenant, hum string }
	denied := []caller{{"anonymous", op, ""}}
	for _, r := range rbac.RoleIDs {
		if r != rbac.Admin {
			denied = append(denied, caller{"operator " + r, op, who[r]})
		}
		denied = append(denied, caller{"other-workspace " + r, other, whoOther[r]})
	}
	for _, c := range denied {
		for _, x := range []struct {
			method, path string
			body         any
		}{{http.MethodGet, sysEventsPath, nil}, {http.MethodPost, del, map[string]any{"ids": ids}}} {
			if code, body := call(t, e, c.tenant, x.method, x.path, c.hum, x.body); code != http.StatusForbidden || body["permission"] != "operator.workspaces" {
				t.Errorf("C13 %s: %s %s = %d %v, want 403 operator.workspaces", c.name, x.method, x.path, code, body)
			}
		}
	}
	p, _ := readLog(t, e, op, fmt.Sprintf("%s?before=%d&limit=3", sysEventsPath, ids[2]+1), who[rbac.Admin], http.StatusOK)
	if len(p.Events) != 3 || p.Events[0].ID != ids[2] || p.Events[2].ID != ids[0] || p.Events[1].Kind != store.LogKindLeaseFailover {
		t.Fatalf("C13 operator admin (CONTROL: nothing was deleted by a denied call): %+v", p)
	}
	code, body := call(t, e, op, http.MethodPost, del, who[rbac.Admin], map[string]any{"ids": ids[:2]})
	if code != http.StatusOK || body["deleted"] != float64(2) {
		t.Fatalf("C14 system delete: %d %v", code, body)
	}
	p, _ = readLog(t, e, op, sysEventsPath+"?limit=1", who[rbac.Admin], http.StatusOK)
	if len(p.Events) != 1 || p.Events[0].Kind != store.LogKindDeleted || p.Events[0].Actor != who[rbac.Admin] || p.Events[0].Message != "2 rows deleted" {
		t.Fatalf("C14 system trace: %+v", p)
	}
	if code, _ := call(t, e, op, http.MethodPost, del, who[rbac.Admin], map[string]any{"ids": []int64{}}); code != http.StatusBadRequest {
		t.Fatalf("system delete of 0 ids: %d, want 400", code)
	}
}

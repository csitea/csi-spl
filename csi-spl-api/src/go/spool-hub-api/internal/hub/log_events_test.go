package hub_test

import (
	"context"
	"encoding/json"
	"fmt"
	"math/rand/v2"
	"net/http"
	"slices"
	"strings"
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

		Fingerprint *string    `json:"fingerprint"`
		FirstAt     *time.Time `json:"first_at"`
		N           *int       `json:"n"`
		IssueKey    *string    `json:"issue_key"`
		IssueN      *int       `json:"issue_n"`
		HumanID     *string    `json:"human_id"`
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

// addGroup upserts one error group into the System log through the store.
func addGroup(t *testing.T, e *env, kind, fp string, n int, hum string) store.LogEvent {
	t.Helper()
	last := time.Now().UTC()
	ev, err := e.st.(store.LogEvents).UpsertSystemErrorGroup(context.Background(), store.LogEvent{Kind: kind, Level: store.LogLevelError,
		Actor: "hub", Message: "t4 " + kind, OriginKind: store.LogOriginComponent, OriginRef: "GET /v1/t4",
		Fingerprint: fp, FirstAt: last.Add(-time.Hour), At: last, N: n, HumanID: hum})
	if err != nil {
		t.Fatal(err)
	}
	return ev
}

// addPlain writes n plain System rows of kind through the store.
func addPlain(t *testing.T, e *env, kind string, n int) {
	t.Helper()
	for i := 0; i < n; i++ {
		if _, err := e.st.(store.LogEvents).AddSystemEvent(context.Background(), store.LogEvent{Kind: kind, Actor: "hub",
			Message: fmt.Sprintf("t4 plain %d", i)}, time.Now().UTC()); err != nil {
			t.Fatal(err)
		}
	}
}

// t4Run is one test run's own kind prefix and fingerprints: the System log
// is hub-wide, so on Postgres it holds the other tests' rows and groups,
// and a fixed fingerprint or a bare error. prefix would read them.
type t4Run struct{ prefix, fpA, fpB, fpC, fpUnknown string }

func newT4Run() t4Run {
	tag := make([]byte, 8)
	for i := range tag {
		tag[i] = 'a' + byte(rand.IntN(26))
	}
	fp := func() string { return fmt.Sprintf("%016x", rand.Uint64()) }
	return t4Run{prefix: "error.tfour" + string(tag), fpA: fp(), fpB: fp(), fpC: fp(), fpUnknown: fp()}
}

// C41 hub half (spec 162 10.7, row T4, SPL-6231): GET
// /v1/operator/events?kind=error. lists the error groups only, newest
// first, each with its group fields, paged within the filter, also past
// more than one store read of other rows; a row that is no group carries
// no group field; POST /v1/operator/events/link sets issue_key and
// issue_n = n and keeps the id.
// RED CONTROL: the ?kind= filter as an exact match, or no filter at all,
// fails this test (both seen RED in the T4 commit body).
func TestSystemEventsErrorGroupsC41(t *testing.T) {
	e, op, _, who, _ := operatorEnv(t, func(op, _ string) string { return op })
	adm := who[rbac.Admin]
	x := newT4Run()
	q := sysEventsPath + "?kind=" + x.prefix
	a := addGroup(t, e, x.prefix+"_http", x.fpA, 3, "HUM-7")
	addPlain(t, e, store.LogKindHubStarted, 2)
	b := addGroup(t, e, x.prefix+"_panic", x.fpB, 40, "")
	addPlain(t, e, store.LogKindLeaseFailover, 600)
	c := addGroup(t, e, x.prefix+"_loop", x.fpC, 1, "")
	addPlain(t, e, store.LogKindHubStarted, 1)

	p, _ := readLog(t, e, op, sysEventsPath+"?kind=error.&limit=200", adm, http.StatusOK)
	var fps []string
	for _, r := range p.Events {
		if r.Fingerprint == nil || r.Kind[:6] != "error." {
			t.Fatalf("C41 kind=error. lists a row that is no error group: %+v", r)
		}
		if *r.Fingerprint == x.fpA || *r.Fingerprint == x.fpB || *r.Fingerprint == x.fpC {
			fps = append(fps, *r.Fingerprint)
		}
	}
	if !slices.Equal(fps, []string{x.fpC, x.fpB, x.fpA}) {
		t.Fatalf("C41 kind=error. lists this run's groups as %v, want newest first [%s %s %s]", fps, x.fpC, x.fpB, x.fpA)
	}
	p, _ = readLog(t, e, op, q, adm, http.StatusOK)
	fps = nil
	for _, r := range p.Events {
		fps = append(fps, *r.Fingerprint)
	}
	if !slices.Equal(fps, []string{x.fpC, x.fpB, x.fpA}) || p.NextBefore != 0 {
		t.Fatalf("C41 kind=%s lists %v next_before %d, want [%s %s %s], 0", x.prefix, fps, p.NextBefore, x.fpC, x.fpB, x.fpA)
	}
	g := p.Events[1]
	if g.ID != b.ID || g.Kind != x.prefix+"_panic" || *g.N != 40 || *g.IssueKey != "" || *g.IssueN != 0 || *g.HumanID != "" ||
		g.FirstAt.IsZero() || !g.FirstAt.Before(g.At) {
		t.Errorf("C41 group row fields: %+v", g)
	}
	if r := p.Events[2]; *r.HumanID != "HUM-7" || *r.N != 3 {
		t.Errorf("C41 group a: human %q n %d, want HUM-7 3", *r.HumanID, *r.N)
	}

	p, _ = readLog(t, e, op, q+"&limit=2", adm, http.StatusOK)
	if len(p.Events) != 2 || p.Events[0].ID != c.ID || p.NextBefore != b.ID {
		t.Fatalf("C41 filtered page 1: %+v, want c, b and next_before %d", p, b.ID)
	}
	p, _ = readLog(t, e, op, fmt.Sprintf("%s&limit=2&before=%d", q, p.NextBefore), adm, http.StatusOK)
	if len(p.Events) != 1 || p.Events[0].ID != a.ID || p.NextBefore != 0 {
		t.Fatalf("C41 filtered page 2: %+v, want only a", p)
	}
	if p, _ = readLog(t, e, op, q+"_pan", adm, http.StatusOK); len(p.Events) != 1 || p.Events[0].ID != b.ID {
		t.Fatalf("C41 kind=%s_pan (a prefix, not a whole name): %+v, want only b", x.prefix, p)
	}
	if p, _ = readLog(t, e, op, sysEventsPath+"?kind=lease.", adm, http.StatusOK); len(p.Events) != 50 || p.Events[0].Fingerprint != nil {
		t.Fatalf("C41 kind=lease.: %d rows, want a full page of plain rows without group fields", len(p.Events))
	}
	if p, _ = readLog(t, e, op, sysEventsPath+"?limit=1", adm, http.StatusOK); len(p.Events) != 1 || p.Events[0].Kind != store.LogKindHubStarted ||
		p.Events[0].Fingerprint != nil || p.Events[0].N != nil || p.Events[0].IssueKey != nil || p.Events[0].HumanID != nil {
		t.Fatalf("C41 unfiltered newest row: %+v, want a plain row with no group field", p.Events)
	}

	code, body := call(t, e, op, http.MethodPost, sysEventsPath+"/link", adm, map[string]any{"fingerprint": x.fpB, "issue_key": "SPL-6231"})
	if code != http.StatusOK || body["issue_key"] != "SPL-6231" || body["issue_n"] != float64(40) || body["n"] != float64(40) ||
		body["id"] != float64(b.ID) || body["fingerprint"] != x.fpB {
		t.Fatalf("C41 link: %d %v, want 200 issue_key SPL-6231 issue_n 40, id kept", code, body)
	}
	p, _ = readLog(t, e, op, q, adm, http.StatusOK)
	if r := p.Events[1]; r.ID != b.ID || *r.IssueKey != "SPL-6231" || *r.IssueN != 40 {
		t.Fatalf("C41 read after link: %+v", r)
	}
	if r := p.Events[0]; *r.IssueKey != "" || *r.IssueN != 0 {
		t.Fatalf("C41 link touched another group: %+v", r)
	}
}

// T4 (SPL-6231): the ?kind= value and the link body are checked (400), an
// unknown fingerprint is 404 not_found and links nothing, and every caller
// but an admin of the operator workspace gets 403 operator.workspaces, as on
// the other System log routes.
func TestSystemEventsLinkRefusals(t *testing.T) {
	e, op, other, who, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	adm := who[rbac.Admin]
	x := newT4Run()
	fpA := x.fpA
	addGroup(t, e, x.prefix+"_http", fpA, 2, "")
	link := sysEventsPath + "/link"
	for _, q := range []string{"?kind=Error.", "?kind=.error", "?kind=error%20x", "?kind=error-x", "?kind=" + strings.Repeat("a", 49)} {
		if code, _ := call(t, e, op, http.MethodGet, sysEventsPath+q, adm, nil); code != http.StatusBadRequest {
			t.Errorf("GET %s: %d, want 400", q, code)
		}
	}
	for _, bad := range []any{map[string]any{}, "x", map[string]any{"fingerprint": fpA},
		map[string]any{"issue_key": "SPL-1"},
		map[string]any{"fingerprint": "0123456789ABCDEF", "issue_key": "SPL-1"},
		map[string]any{"fingerprint": "0123456789abcde", "issue_key": "SPL-1"},
		map[string]any{"fingerprint": fpA + "0", "issue_key": "SPL-1"},
		map[string]any{"fingerprint": fpA, "issue_key": "spl-1"},
		map[string]any{"fingerprint": fpA, "issue_key": "SPL-0"},
		map[string]any{"fingerprint": fpA, "issue_key": "ABC-1"},
		map[string]any{"fingerprint": fpA, "issue_key": "SPL-"},
		map[string]any{"fingerprint": fpA, "issue_key": "SPL-1", "issue_n": 9}} {
		if code, body := call(t, e, op, http.MethodPost, link, adm, bad); code != http.StatusBadRequest {
			t.Errorf("link body %v: %d %v, want 400", bad, code, body)
		}
	}
	if code, body := call(t, e, op, http.MethodPost, link, adm, map[string]any{"fingerprint": x.fpUnknown, "issue_key": "SPL-1"}); code != http.StatusNotFound || body["error"] != "not_found" {
		t.Errorf("link of an unknown fingerprint: %d %v, want 404 not_found", code, body)
	}
	type caller struct{ name, tenant, hum string }
	denied := []caller{{"anonymous", op, ""}}
	for _, r := range rbac.RoleIDs {
		if r != rbac.Admin {
			denied = append(denied, caller{"operator " + r, op, who[r]})
		}
		denied = append(denied, caller{"other-workspace " + r, other, whoOther[r]})
	}
	for _, c := range denied {
		if code, body := call(t, e, c.tenant, http.MethodPost, link, c.hum, map[string]any{"fingerprint": fpA, "issue_key": "SPL-1"}); code != http.StatusForbidden || body["permission"] != "operator.workspaces" {
			t.Errorf("link as %s: %d %v, want 403 operator.workspaces", c.name, code, body)
		}
		if code, _ := call(t, e, c.tenant, http.MethodGet, sysEventsPath+"?kind=error.", c.hum, nil); code != http.StatusForbidden {
			t.Errorf("GET ?kind=error. as %s: %d, want 403", c.name, code)
		}
	}
	p, _ := readLog(t, e, op, sysEventsPath+"?kind="+x.prefix, adm, http.StatusOK)
	if len(p.Events) != 1 || *p.Events[0].IssueKey != "" || *p.Events[0].IssueN != 0 {
		t.Fatalf("CONTROL: a refused link changed the group: %+v", p.Events)
	}
}

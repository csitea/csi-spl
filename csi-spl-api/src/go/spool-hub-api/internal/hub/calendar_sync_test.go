package hub_test

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/hex"
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

// specs/112 HUB-1: PUT /v1/calendar/sync. The deploy identity alone writes
// (an agent token and a member session are 403); a goal is published only on
// an approval message of a holder of the approver role (D2); the cnf keys
// fail the sync fast; a partial batch never soft-deletes the goals (the
// STORE-1 finding: this route prunes only the key families it carries); a
// synced event is 409 to PATCH and DELETE and found by ?source_key=. Memory,
// and Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

const syncPath = "/v1/calendar/sync"

// syncEnv is a hub whose roadmap workspace is a fresh tenant, approver role
// role ("" = the cnf key missing), with the operator token "good".
func syncEnv(t *testing.T, role string) (*env, string) {
	t.Helper()
	b := make([]byte, 4)
	rand.Read(b) //nolint:errcheck
	tid := "rm" + hex.EncodeToString(b)
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
		o.RoadmapTenant, o.RoadmapApproverRole = tid, role
	})
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: tid, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	return e, tid
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

func syncGoal(id, msgID string) map[string]any {
	return map[string]any{"id": id, "approval": map[string]any{"msg_id": msgID}}
}

func syncEv(key, day string) map[string]any {
	kind := "goal"
	switch {
	case strings.HasPrefix(key, "spec:"):
		kind = "milestone"
	case strings.HasPrefix(key, "release:"):
		kind = "release"
	}
	return map[string]any{"source_key": key, "title": key, "kind": kind, "starts_at": day + "T00:00:00Z",
		"ends_at": day + "T00:00:00Z", "all_day": true, "audience": "workspace", "roadmap_url": "/roadmap?goal=G01"}
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
	evs, err := e.st.(store.CalendarSourced).CalendarBySourceKey(context.Background(), tid, "", "")
	if err != nil {
		t.Fatal(err)
	}
	var ks []string
	for _, ev := range evs {
		ks = append(ks, ev.SourceKey)
	}
	sort.Strings(ks)
	return strings.Join(ks, ",")
}

func num(out map[string]any, k string) int {
	f, _ := out[k].(float64)
	return int(f)
}

func TestCalendarSyncDeployIdentityOnly(t *testing.T) {
	e, tid := syncEnv(t, rbac.Admin)
	admin, dev := seat(t, e, tid, rbac.Admin), seat(t, e, tid, rbac.Developer)
	b := e.box(tid, "box-a", "c-001")
	e.pin(tid, b)
	agent := e.uploadToken(tid, b)
	body := map[string]any{"goals": []any{}, "events": []any{syncEv("release:v1.3.0", "2026-10-01")}}

	// CONTROL: an agent token is 403, though a bearer
	if code, out := opCall(t, e, tid, http.MethodPut, syncPath, agent, body); code != http.StatusForbidden || out["error"] != "deploy_identity_only" {
		t.Fatalf("agent token: %d %v", code, out)
	}
	// a member session, the approver role's holder included, is 403
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
	if code != http.StatusOK || num(out, "created") != 1 || out["tenant"] != tid {
		t.Fatalf("deploy identity: %d %v", code, out)
	}
	_, list := call(t, e, tid, http.MethodGet, "/v1/calendar/events?source_key=release:", dev, nil)
	evs, _ := list["events"].([]any)
	if len(evs) != 1 {
		t.Fatalf("release listed: %v", list)
	}
	ev := evs[0].(map[string]any)
	if ev["creator_type"] != "system" || ev["creator_id"] != "roadmap-sync" || ev["source_key"] != "release:v1.3.0" ||
		ev["roadmap_url"] != "/roadmap?goal=G01" {
		t.Fatalf("synced event: %v", ev)
	}
}

func TestCalendarSyncApproval(t *testing.T) {
	e, tid := syncEnv(t, rbac.Admin)
	admin, dev := seat(t, e, tid, rbac.Admin), seat(t, e, tid, rbac.Developer)
	other, _ := e.tenant()
	elsewhere := seat(t, e, other, rbac.Admin)
	goals := []map[string]any{
		syncGoal("G01-first", approvalMsg(t, e, tid, admin, "")),
		// CONTROL: an approval message from a non-admin member writes nothing
		syncGoal("G02-second", approvalMsg(t, e, tid, dev, "")),
		syncGoal("G03-draft", ""),
		syncGoal("G04-boxed", approvalMsg(t, e, tid, admin, "box-a")),
		syncGoal("G05-elsewhere", approvalMsg(t, e, other, elsewhere, "")),
		syncGoal("G06-short", "5a9aab48"),
	}
	var events []map[string]any
	for _, g := range []string{"G01", "G02", "G03", "G04", "G05", "G06"} {
		events = append(events, syncEv("goal:"+g+":deadline", "2026-12-31"))
	}
	code, out := syncCall(t, e, tid, goals, events)
	if code != http.StatusOK || num(out, "created") != 1 {
		t.Fatalf("sync: %d %v", code, out)
	}
	if got := liveKeys(t, e, tid); got != "goal:G01:deadline" {
		t.Fatalf("written: %q", got)
	}
	un, _ := out["unapproved"].([]any)
	var ids []string
	for _, u := range un {
		m := u.(map[string]any)
		if m["reason"] == "" {
			t.Fatalf("no reason: %v", m)
		}
		ids = append(ids, m["id"].(string))
	}
	if strings.Join(ids, ",") != "G02-second,G03-draft,G04-boxed,G05-elsewhere,G06-short" {
		t.Fatalf("unapproved: %v", un)
	}
	// the approver role is cnf, not a fixed id: with developer, G02 is the approved one
	e2, tid2 := syncEnv(t, rbac.Developer)
	dev2, admin2 := seat(t, e2, tid2, rbac.Developer), seat(t, e2, tid2, rbac.Admin)
	code, out = syncCall(t, e2, tid2, []map[string]any{syncGoal("G01-first", approvalMsg(t, e2, tid2, admin2, "")),
		syncGoal("G02-second", approvalMsg(t, e2, tid2, dev2, ""))}, events[:2])
	if code != http.StatusOK || liveKeys(t, e2, tid2) != "goal:G02:deadline" {
		t.Fatalf("approver developer: %d %v %q", code, out, liveKeys(t, e2, tid2))
	}
	// a goal: key that names no goal in goals is refused whole
	if code, out := syncCall(t, e, tid, goals[:1], events[:2]); code != http.StatusBadRequest || out["error"] != "bad_event" {
		t.Fatalf("unknown goal key: %d %v", code, out)
	}
	// the audience rename (rdb 0159): a sync's public meant workspace before
	// it, so public is refused whole, never put on the internet; so is web
	for _, aud := range []string{"public", "web"} {
		ev := syncEv("release:v1.3.0", "2026-10-01")
		ev["audience"] = aud
		if code, out := syncCall(t, e, tid, nil, []map[string]any{ev}); code != http.StatusBadRequest || out["error"] != "bad_event" {
			t.Fatalf("sync audience %s: %d %v", aud, code, out)
		}
	}
}

func TestCalendarSyncConfigFailsFast(t *testing.T) {
	events := []map[string]any{syncEv("release:v1.3.0", "2026-10-01")}
	// CONTROL: a missing approver_role key fails the sync before any write
	for _, role := range []string{"", "no-such-role"} {
		e, tid := syncEnv(t, role)
		code, out := syncCall(t, e, tid, nil, events)
		if code != http.StatusServiceUnavailable || out["error"] != "roadmap_not_configured" {
			t.Fatalf("approver_role %q: %d %v", role, code, out)
		}
		if got := liveKeys(t, e, tid); got != "" {
			t.Fatalf("approver_role %q wrote %q", role, got)
		}
	}
	e := rbacEnv(t, func(o *hub.Options) {
		o.OperatorEmails = []string{operatorSA}
		o.OperatorVerify = func(context.Context, string, string) (string, error) { return operatorSA, nil }
		o.RoadmapApproverRole = rbac.Admin
	})
	tid, _ := e.tenant()
	if code, out := syncCall(t, e, tid, nil, events); code != http.StatusServiceUnavailable || !strings.Contains(out["detail"].(string), "tenant_id") {
		t.Fatalf("no tenant_id: %d %v", code, out)
	}
}

func TestCalendarSyncPartialBatchKeepsGoals(t *testing.T) {
	e, tid := syncEnv(t, rbac.Admin)
	admin := seat(t, e, tid, rbac.Admin)
	goals := []map[string]any{syncGoal("G01-first", approvalMsg(t, e, tid, admin, ""))}
	full := []map[string]any{syncEv("goal:G01:deadline", "2026-12-31"), syncEv("goal:G01:m:start", "2026-09-17"),
		syncEv("spec:089:done", "2026-10-02")}
	if code, out := syncCall(t, e, tid, goals, full); code != http.StatusOK || num(out, "created") != 3 {
		t.Fatalf("full: %d %v", code, out)
	}
	// the same batch again changes nothing
	if code, out := syncCall(t, e, tid, goals, full); code != http.StatusOK || num(out, "unchanged") != 3 || num(out, "created") != 0 {
		t.Fatalf("re-run: %d %v", code, out)
	}
	// CONTROL (finding 1): the 8.1 backfill's release: keys alone delete nothing
	code, out := syncCall(t, e, tid, nil, []map[string]any{syncEv("release:v1.3.0", "2026-10-01")})
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
	code, out = syncCall(t, e, tid, []map[string]any{syncGoal("G01-first", "")}, full[:1])
	if code != http.StatusOK || num(out, "deleted") != 1 || liveKeys(t, e, tid) != "release:v1.3.0,spec:089:done" {
		t.Fatalf("unapproved: %d %v %q", code, out, liveKeys(t, e, tid))
	}
}

func TestCalendarSyncedReadOnlyAndLookup(t *testing.T) {
	e, tid := syncEnv(t, rbac.Admin)
	admin := seat(t, e, tid, rbac.Admin)
	goals := []map[string]any{syncGoal("G01-first", approvalMsg(t, e, tid, admin, "")),
		syncGoal("G11-eleventh", approvalMsg(t, e, tid, admin, ""))}
	events := []map[string]any{syncEv("goal:G01:deadline", "2026-12-31"), syncEv("goal:G01:m:start", "2026-09-17"),
		syncEv("goal:G11:deadline", "2027-06-30")}
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

package hub_test

import (
	"bytes"
	"context"
	"encoding/json"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 118 T004: the person's save across workspaces (PUT /v1/me/realm/hours)
// and the targets one workspace offers (GET /v1/me/realm/targets). Tests
// T-D2, T-R4a, T-R4b, T-R4c, plus T-R1c's write half, T-RLS2's write half
// and T-RLS6's access half. Memory, and Postgres under SPOOL_TEST_PG_DSN
// (PRE_PUSH_TIER=full). The hub clock is hoursNow (Wed 2026-10-07 12:00
// UTC); the week of Mon 10-05 is open in every workspace.

const realmWriteDay = "2026-10-06"

// realmWriteRig is the person P, a member of the workspaces A and B.
type realmWriteRig struct {
	e     *env
	a, b  string
	p     string
	email string // P's sign-in e-mail
}

func newRealmWriteRig(t *testing.T) realmWriteRig {
	t.Helper()
	e, a := hoursEnv(t)
	b, _ := e.tenant()
	r := realmWriteRig{e: e, a: a, b: b, email: "p-" + randHex(5) + "@example.com"}
	r.p = rwSeatAs(t, e, r.email, a, rbac.Developer)
	if got := rwSeatAs(t, e, r.email, b, rbac.Developer); got != r.p {
		t.Fatalf("second admit made %s, want %s", got, r.p)
	}
	return r
}

// rwCall is a realm route called on host's page with extra headers.
func rwCall(t *testing.T, e *env, host, method, path, as string, body any, hdr map[string]string) (int, map[string]any) {
	t.Helper()
	var raw []byte
	if body != nil {
		raw, _ = json.Marshal(body)
	}
	req, _ := http.NewRequest(method, e.url(host)+path, bytes.NewReader(raw))
	req.Header.Set("Content-Type", "application/json")
	if as != "" {
		req.Header.Set(memberHeader, as)
	}
	for k, v := range hdr {
		req.Header.Set(k, v)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	out := map[string]any{}
	json.NewDecoder(resp.Body).Decode(&out) //nolint:errcheck
	return resp.StatusCode, out
}

// rwSave is a PUT /v1/me/realm/hours that must answer 200: its rows by op_id.
func rwSave(t *testing.T, r realmWriteRig, rows ...map[string]any) map[string]map[string]any {
	t.Helper()
	code, out := rwCall(t, r.e, r.a, http.MethodPut, "/v1/me/realm/hours", r.p, rows, nil)
	if code != http.StatusOK {
		t.Fatalf("PUT /v1/me/realm/hours: %d %v", code, out)
	}
	got := map[string]map[string]any{}
	list, _ := out["rows"].([]any)
	for _, x := range list {
		m := x.(map[string]any)
		got[m["op_id"].(string)] = m
	}
	if len(got) != len(rows) {
		t.Fatalf("answer has %d rows for %d: %v", len(got), len(rows), out)
	}
	return got
}

func rwMinutesRow(ws, op, day, target string, minutes int) map[string]any {
	return map[string]any{"workspace": ws, "op_id": op, "day": day, "target": target, "minutes": minutes}
}

func rwTimedRow(ws, op, target, start, end string) map[string]any {
	return map[string]any{"workspace": ws, "op_id": op, "target": target, "start": start, "end": end}
}

func rwWantStatus(t *testing.T, got map[string]map[string]any, op, status string) {
	t.Helper()
	if got[op]["status"] != status {
		t.Fatalf("row %s: %v, want %s", op, got[op], status)
	}
}

// rwEntries is P's entries of day in ws, as the workspace's store holds
// them (read under that workspace's scope): minutes by target.
func rwEntries(t *testing.T, r realmWriteRig, ws, day string) map[string]int {
	t.Helper()
	es, err := hoursStore(r.e).HoursEntries(context.Background(), ws, r.p, day, day)
	if err != nil {
		t.Fatal(err)
	}
	out := map[string]int{}
	for _, e := range es {
		out[e.Target] = e.Minutes
	}
	return out
}

func rwSpans(t *testing.T, r realmWriteRig, ws, day string) []store.HoursEntrySpan {
	t.Helper()
	sp, err := hoursStore(r.e).HoursEntrySpans(context.Background(), ws, r.p, day, day)
	if err != nil {
		t.Fatal(err)
	}
	return sp
}

// T-R4a + T-R1c: one save with rows for A and B lands each in its own
// workspace; the same span in A and in B is saved in both (D2); a replay
// writes nothing new.
func TestRealmHoursSaveEachWorkspace(t *testing.T) {
	r := newRealmWriteRig(t)
	rows := []map[string]any{
		rwMinutesRow(r.a, "a1", realmWriteDay, "ws", 60),
		rwTimedRow(r.a, "a2", "ch:"+store.ChannelLobby, realmWriteDay+"T09:00:00Z", realmWriteDay+"T11:00:00Z"),
		rwTimedRow(r.b, "b1", "ws", realmWriteDay+"T09:00:00Z", realmWriteDay+"T11:00:00Z"),
	}
	got := rwSave(t, r, rows...)
	for _, op := range []string{"a1", "a2", "b1"} {
		rwWantStatus(t, got, op, "ok")
	}
	if a := rwEntries(t, r, r.a, realmWriteDay); len(a) != 2 || a["ws"] != 60 || a["ch:"+store.ChannelLobby] != 120 {
		t.Fatalf("A holds %v", a)
	}
	if b := rwEntries(t, r, r.b, realmWriteDay); len(b) != 1 || b["ws"] != 120 {
		t.Fatalf("B holds %v", b)
	}
	if sp := rwSpans(t, r, r.b, realmWriteDay); len(sp) != 1 || sp[0].Src != store.HoursSpanManual ||
		!sp[0].Start.Equal(time.Date(2026, 10, 6, 9, 0, 0, 0, time.UTC)) {
		t.Fatalf("B spans %v", sp)
	}
	// Each workspace's own GET /v1/me/hours shows only its own row.
	if row := hoursRow(t, myHours(t, r.e, r.b, r.p, realmWriteDay), realmWriteDay, "ch:"+store.ChannelLobby); row != nil {
		t.Fatalf("A's row shows in B: %v", row)
	}
	// The replay: every row ok, the timed ones replayed, nothing doubled.
	got = rwSave(t, r, rows...)
	for _, op := range []string{"a1", "a2", "b1"} {
		rwWantStatus(t, got, op, "ok")
	}
	if got["a2"]["replayed"] != true || got["b1"]["replayed"] != true || got["a1"]["replayed"] != nil {
		t.Fatalf("replay flags: %v", got)
	}
	if a := rwEntries(t, r, r.a, realmWriteDay); a["ch:"+store.ChannelLobby] != 120 || a["ws"] != 60 {
		t.Fatalf("replay changed A: %v", a)
	}
	if b := rwEntries(t, r, r.b, realmWriteDay); b["ws"] != 120 || len(rwSpans(t, r, r.b, realmWriteDay)) != 1 {
		t.Fatalf("replay changed B: %v", b)
	}
	// CONTROL: a second span on the same target adds to the row.
	got = rwSave(t, r, rwTimedRow(r.b, "b2", "ws", realmWriteDay+"T13:00:00Z", realmWriteDay+"T13:30:00Z"))
	rwWantStatus(t, got, "b2", "ok")
	if b := rwEntries(t, r, r.b, realmWriteDay); b["ws"] != 150 {
		t.Fatalf("second span: B holds %v, want 150", b)
	}
}

// T-R4b: B's period frozen -> A saved, B period_frozen, A not rolled back; a
// replay writes nothing new; after a Return, B saves once.
func TestRealmHoursPartialRefusal(t *testing.T) {
	r := newRealmWriteRig(t)
	ctx := context.Background()
	hs := hoursStore(r.e)
	if _, err := hs.CreateHoursPeriod(ctx, r.b, store.HoursPeriod{Member: r.p, Start: hoursThisWeek, End: "2026-10-11",
		State: store.HoursFrozen, DecidedBy: "sweep", DecidedAt: hoursNow}); err != nil {
		t.Fatal(err)
	}
	rows := []map[string]any{rwMinutesRow(r.a, "a1", realmWriteDay, "ws", 90), rwMinutesRow(r.b, "b1", realmWriteDay, "ws", 45)}
	for range 2 {
		got := rwSave(t, r, rows...)
		rwWantStatus(t, got, "a1", "ok")
		rwWantStatus(t, got, "b1", "period_frozen")
		if a, b := rwEntries(t, r, r.a, realmWriteDay), rwEntries(t, r, r.b, realmWriteDay); len(a) != 1 || a["ws"] != 90 || len(b) != 0 {
			t.Fatalf("A %v, B %v", a, b)
		}
	}
	if _, err := hs.SetHoursPeriodState(ctx, r.b, r.p, hoursThisWeek, store.HoursPeriodChange{State: store.HoursReturned,
		Note: "add Tuesday", By: "HUM-owner", At: hoursNow}); err != nil {
		t.Fatal(err)
	}
	got := rwSave(t, r, rows[1])
	rwWantStatus(t, got, "b1", "ok")
	if b := rwEntries(t, r, r.b, realmWriteDay); b["ws"] != 45 {
		t.Fatalf("B after the Return: %v", b)
	}
}

// T-RLS2 (write half): a workspace P is not in, or where P's seat enters no
// hours, fails not_a_member and gets 0 rows; the others are saved.
func TestRealmHoursNotAMember(t *testing.T) {
	r := newRealmWriteRig(t)
	c, _ := r.e.tenant()
	seat(t, r.e, c, rbac.Developer)
	d, _ := r.e.tenant()
	if got := rwSeatAs(t, r.e, r.email, d, rbac.DemoUser); got != r.p {
		t.Fatalf("demo admit made %s, want %s", got, r.p)
	}
	got := rwSave(t, r, rwMinutesRow(c, "c1", realmWriteDay, "ws", 30), rwMinutesRow(r.a, "a1", realmWriteDay, "ws", 30))
	rwWantStatus(t, got, "c1", "not_a_member")
	rwWantStatus(t, got, "a1", "ok")
	if n := rwEntries(t, r, c, realmWriteDay); len(n) != 0 {
		t.Fatalf("C holds %v", n)
	}
	// A demo seat holds no self.keys: P enters no hours of their own in D.
	got = rwSave(t, r, rwMinutesRow(d, "d1", realmWriteDay, "ws", 30))
	rwWantStatus(t, got, "d1", "not_a_member")
	// A demo-only session cannot save at all (as PUT /v1/me/hours).
	demo := seat(t, r.e, d, rbac.DemoUser)
	if code, _ := rwCall(t, r.e, d, http.MethodPut, "/v1/me/realm/hours", demo,
		[]map[string]any{rwMinutesRow(d, "d1", realmWriteDay, "ws", 30)}, nil); code != http.StatusForbidden {
		t.Fatalf("demo session: %d, want 403", code)
	}
}

// rwSeatAs admits the human signing in with email to tid with role.
func rwSeatAs(t *testing.T, e *env, email, tid, role string) string {
	t.Helper()
	h := e.st.(store.Humans)
	now := time.Now()
	if err := h.PutInvite(context.Background(), store.Invite{TenantID: tid, Email: email, Role: role,
		InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	hum, err := h.Admit(context.Background(), store.Identity{Provider: "google", Subject: "s-" + email, Email: email}, tid, store.AdmitPolicy{}, now)
	if err != nil {
		t.Fatal(err)
	}
	return hum
}

// T-R4c: B's picker never offers an A target, and an A target written into
// B is unknown_target (CONTROL: the same target in A is offered and saved).
func TestRealmHoursTargets(t *testing.T) {
	r := newRealmWriteRig(t)
	task := putTopic(t, r.e, r.a, store.ChannelLobby, "Paving the yard", hoursNow.Add(-time.Hour))
	has := func(ws, q string) bool {
		code, out := rwCall(t, r.e, r.a, http.MethodGet, "/v1/me/realm/targets?workspace="+ws+"&q="+q, r.p, nil, nil)
		if code != http.StatusOK || out["workspace"] != ws {
			t.Fatalf("targets of %s: %d %v", ws, code, out)
		}
		list, _ := out["targets"].([]any)
		for _, x := range list {
			if x.(map[string]any)["target"] == "t:"+task {
				return true
			}
		}
		return false
	}
	if !has(r.a, "") || !has(r.a, "paving") {
		t.Fatal("CONTROL: A does not offer its own topic")
	}
	if has(r.b, "") || has(r.b, "paving") {
		t.Fatal("B offers A's topic")
	}
	if has(r.a, "no-such-words") {
		t.Fatal("q does not filter")
	}
	got := rwSave(t, r, rwMinutesRow(r.b, "b1", realmWriteDay, "t:"+task, 30), rwMinutesRow(r.a, "a1", realmWriteDay, "t:"+task, 30))
	rwWantStatus(t, got, "b1", "unknown_target")
	rwWantStatus(t, got, "a1", "ok")
	if b := rwEntries(t, r, r.b, realmWriteDay); len(b) != 0 {
		t.Fatalf("B holds %v", b)
	}
	c, _ := r.e.tenant()
	if code, out := rwCall(t, r.e, r.a, http.MethodGet, "/v1/me/realm/targets?workspace="+c, r.p, nil, nil); code != http.StatusForbidden || out["error"] != "not_a_member" {
		t.Fatalf("targets of a workspace P is not in: %d %v", code, out)
	}
}

// Within one workspace an overlap refuses that workspace's group (REQ-1, 409
// overlap_in_workspace in 107's write); across workspaces nothing is refused.
// A timed row across midnight is split at the workspace's midnight; a day
// above 1440 minutes is day_over_1440.
func TestRealmHoursOverlapSplitCap(t *testing.T) {
	r := newRealmWriteRig(t)
	got := rwSave(t, r,
		rwTimedRow(r.a, "a1", "ws", realmWriteDay+"T09:00:00Z", realmWriteDay+"T10:00:00Z"),
		rwTimedRow(r.a, "a2", "ch:"+store.ChannelLobby, realmWriteDay+"T09:30:00Z", realmWriteDay+"T10:30:00Z"),
		rwTimedRow(r.b, "b1", "ws", realmWriteDay+"T09:30:00Z", realmWriteDay+"T10:30:00Z"))
	rwWantStatus(t, got, "a1", "overlap_in_workspace")
	rwWantStatus(t, got, "a2", "overlap_in_workspace")
	rwWantStatus(t, got, "b1", "ok")
	if a := rwEntries(t, r, r.a, realmWriteDay); len(a) != 0 {
		t.Fatalf("A holds %v after its refusal", a)
	}

	got = rwSave(t, r, rwTimedRow(r.a, "m1", "ws", "2026-10-05T22:00:00Z", realmWriteDay+"T02:00:00Z"))
	rwWantStatus(t, got, "m1", "ok")
	if mon, tue := rwEntries(t, r, r.a, "2026-10-05"), rwEntries(t, r, r.a, realmWriteDay); mon["ws"] != 120 || tue["ws"] != 120 {
		t.Fatalf("midnight split: mon %v tue %v", mon, tue)
	}

	got = rwSave(t, r, rwMinutesRow(r.b, "c1", "2026-10-05", "ws", 1000),
		rwMinutesRow(r.b, "c2", "2026-10-05", "ch:"+store.ChannelLobby, 500))
	rwWantStatus(t, got, "c1", "day_over_1440")
	rwWantStatus(t, got, "c2", "day_over_1440")
}

// T-D2 and the batch's shape: split / share / percent are 400 no_split; a
// row with minutes AND times, a missing op_id, an op_id twice are 400.
func TestRealmHoursRefusesSplitAndBadShapes(t *testing.T) {
	r := newRealmWriteRig(t)
	put := func(rows any) (int, map[string]any) {
		return rwCall(t, r.e, r.a, http.MethodPut, "/v1/me/realm/hours", r.p, rows, nil)
	}
	for _, k := range []string{"split", "share", "percent"} {
		row := rwMinutesRow(r.a, "a1", realmWriteDay, "ws", 60)
		row[k] = 50
		if code, out := put([]any{row}); code != http.StatusBadRequest || out["error"] != "no_split" {
			t.Fatalf("%s: %d %v", k, code, out)
		}
	}
	both := rwMinutesRow(r.a, "a1", realmWriteDay, "ws", 60)
	both["start"], both["end"] = realmWriteDay+"T09:00:00Z", realmWriteDay+"T10:00:00Z"
	noOp := rwMinutesRow(r.a, "", realmWriteDay, "ws", 60)
	for name, rows := range map[string]any{
		"minutes and times": []any{both},
		"no op_id":          []any{noOp},
		"op_id twice":       []any{rwMinutesRow(r.a, "x", realmWriteDay, "ws", 1), rwMinutesRow(r.b, "x", realmWriteDay, "ws", 1)},
		"empty":             []any{},
		"not an array":      map[string]any{"rows": []any{}},
	} {
		if code, _ := put(rows); code != http.StatusBadRequest {
			t.Fatalf("%s: %d, want 400", name, code)
		}
	}
	if a := rwEntries(t, r, r.a, realmWriteDay); len(a) != 0 {
		t.Fatalf("a refused batch wrote %v", a)
	}
	// CONTROL: the same row without the split field saves.
	rwWantStatus(t, rwSave(t, r, rwMinutesRow(r.a, "a1", realmWriteDay, "ws", 60)), "a1", "ok")
}

// T-RLS6 (access half): X-Spool-Tenant or member= is 400 person_scope, no
// session is 401, a box credential is 403 person_only, and so is an act-as
// clone (Postgres).
func TestRealmHoursWritePersonOnly(t *testing.T) {
	r := newRealmWriteRig(t)
	rows := []map[string]any{rwMinutesRow(r.a, "a1", realmWriteDay, "ws", 60)}
	for _, path := range []string{"/v1/me/realm/hours", "/v1/me/realm/targets?workspace=" + r.a} {
		method := http.MethodPut
		var body any = rows
		if path != "/v1/me/realm/hours" {
			method, body = http.MethodGet, nil
		}
		if code, out := rwCall(t, r.e, r.a, method, path, r.p, body, map[string]string{hub.TenantHeader: r.a}); code != http.StatusBadRequest || out["error"] != "person_scope" {
			t.Fatalf("%s %s with %s: %d %v", method, path, hub.TenantHeader, code, out)
		}
		sep := "?"
		if method == http.MethodGet {
			sep = "&"
		}
		if code, out := rwCall(t, r.e, r.a, method, path+sep+"member="+r.p, r.p, body, nil); code != http.StatusBadRequest || out["error"] != "person_scope" {
			t.Fatalf("%s %s with member=: %d %v", method, path, code, out)
		}
		if code, out := rwCall(t, r.e, r.a, method, path, "", body, nil); code != http.StatusUnauthorized || out["error"] != "view_door" {
			t.Fatalf("%s %s without a session: %d %v", method, path, code, out)
		}
		if code, out := rwCall(t, r.e, r.a, method, path, "", body, map[string]string{"Authorization": "Bearer box-token"}); code != http.StatusForbidden || out["error"] != "person_only" {
			t.Fatalf("%s %s with a box credential: %d %v", method, path, code, out)
		}
	}
	if a := rwEntries(t, r, r.a, realmWriteDay); len(a) != 0 {
		t.Fatalf("a refused caller wrote %v", a)
	}
	cs, ok := r.e.st.(dmCloneStore)
	if !ok {
		t.Log("act-as clone leg needs Postgres (SPOOL_TEST_PG_DSN)")
		return
	}
	now := time.Now().UTC()
	cl, err := cs.StartClone(context.Background(), store.CloneStart{TenantID: r.a, TargetHum: r.p, AdminName: "Admin",
		CreatedBy: r.p, ExpiresAt: now.Add(time.Hour)}, now)
	if err != nil {
		t.Fatal(err)
	}
	if code, out := rwCall(t, r.e, r.a, http.MethodPut, "/v1/me/realm/hours", cl.CloneHum, rows, nil); code != http.StatusForbidden || out["error"] != "person_only" {
		t.Fatalf("act-as clone: %d %v", code, out)
	}
}

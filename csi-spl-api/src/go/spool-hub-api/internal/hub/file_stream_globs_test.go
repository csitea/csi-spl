package hub_test

import (
	"context"
	"errors"
	"net/http"
	"strconv"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 160 row B9 (SPL-4294, rdb 0242): file globs typed in the web page,
// cases C41..C46. Memory always, Postgres with a DSN (hub-pg.tst.sh). Red
// on origin/master before SPL-4294: no /v1/file-streams/globs route (every
// POST 404/405, so the admin's 201 below fails) and no file_streams_globs
// lane op (bad_frame). Each case's planted defect is named on its test; the
// red runs are in the commit body.

const (
	fsGlobsPath     = "/v1/file-streams/globs"
	fsGlobsViewPath = "/v1/view/file-streams/globs"
	fsGlobsAudit    = "/v1/view/file-streams/globs/audit"
)

// fsGlobRig is fsRig with box-a of W announcing stream "app" and the allowed
// folder /var/log, and box-b of W announcing it too; W2's box-a announces
// nothing.
func fsGlobRig(t *testing.T, mut ...func(*hub.Options)) (*fsRig, *box) {
	t.Helper()
	r := newFSRig(t, store.FileStreamLimits{}, mut...)
	b := r.e.box(r.w, "box-b")
	r.e.pin(r.w, b)
	for _, x := range []*box{r.a, b} {
		if _, err := r.lane(t, x, wire.FileStreamsAnnounceOp, fsGlobAnnounce("")); err != nil {
			t.Fatal(err)
		}
	}
	return r, b
}

// fsGlobAnnounce is stream "app" plus the folders /var/log (allowed) and
// /etc (refused), and globs (a JSON list, "" for none).
func fsGlobAnnounce(globs string) string {
	out := `{"streams":[{"stream_key":"app","path":"/var/log/app.log","state":"following"}],` +
		`"folders":[{"path":"/var/log","state":"allowed"},{"path":"/etc","state":"refused","reason":"too short"}]`
	if globs != "" {
		out += `,"globs":` + globs
	}
	return out + `}`
}

func fsGlob(box, key, glob string) map[string]any {
	return map[string]any{"box_id": box, "key": key, "glob": glob}
}

func fsDelete(t *testing.T, e *env, tid, id, as string) int {
	t.Helper()
	code, _ := call(t, e, tid, http.MethodDelete, fsGlobsPath+"/"+id, as, nil)
	return code
}

// TestFileStreamGlobRBAC (case C41): an owner and an admin of W get 201 on
// POST, 200 on both GETs, 204 on DELETE; a member (developer) and a call
// with no member session (a box, the operator service account) get 403 (or
// 401) on all four. PLANTED DEFECT: a membership-only gate (humanTenant
// without fileStreamsStaffRefusal) gives the developer 201.
func TestFileStreamGlobRBAC(t *testing.T) {
	r, _ := fsGlobRig(t)
	owner, admin, dev := seat(t, r.e, r.w, rbac.BizOwner), seat(t, r.e, r.w, rbac.Admin), seat(t, r.e, r.w, rbac.Developer)
	for i, as := range []string{owner, admin} {
		code, body := call(t, r.e, r.w, http.MethodPost, fsGlobsPath, as, fsGlob("box-a", "app"+string(rune('a'+i)), "/var/log/app*.log"))
		if code != http.StatusCreated || body["state"] != wire.FileStreamGlobPending || body["created_by"] != as {
			t.Fatalf("POST as %s = %d %v, want 201 pending", as, code, body)
		}
		for _, p := range []string{fsGlobsViewPath, fsGlobsAudit} {
			if code, b := get(t, r.e, r.w, p, as); code != http.StatusOK {
				t.Errorf("GET %s as %s = %d %s, want 200", p, as, code, b)
			}
		}
		if code := fsDelete(t, r.e, r.w, body["id"].(string), as); code != http.StatusNoContent {
			t.Errorf("DELETE as %s = %d, want 204", as, code)
		}
	}
	code, body := call(t, r.e, r.w, http.MethodPost, fsGlobsPath, admin, fsGlob("box-a", "kept", "/var/log/kept*.log"))
	if code != http.StatusCreated {
		t.Fatalf("seed: %d %v", code, body)
	}
	id := body["id"].(string)
	for _, as := range []string{dev, ""} {
		if code, b := call(t, r.e, r.w, http.MethodPost, fsGlobsPath, as, fsGlob("box-a", "dev", "/var/log/dev*.log")); code != http.StatusForbidden && code != http.StatusUnauthorized {
			t.Errorf("POST as %q = %d %v, want 403", as, code, b)
		}
		for _, p := range []string{fsGlobsViewPath, fsGlobsAudit} {
			if code, _ := get(t, r.e, r.w, p, as); code != http.StatusForbidden && code != http.StatusUnauthorized {
				t.Errorf("GET %s as %q = %d, want 403", p, as, code)
			}
		}
		if code := fsDelete(t, r.e, r.w, id, as); code != http.StatusForbidden && code != http.StatusUnauthorized {
			t.Errorf("DELETE as %q = %d, want 403", as, code)
		}
	}
}

// TestFileStreamGlobOperatorSA (case C41): the operator service account's
// Bearer token on the four routes is 401/403.
func TestFileStreamGlobOperatorSA(t *testing.T) {
	op := newTenantID("op")
	r, _ := fsGlobRig(t, func(o *hub.Options) {
		o.OperatorTenant = op
		o.OperatorEmails = []string{operatorSA}
		o.OperatorAudience = "https://api.dev.example"
		o.OperatorVerify = func(_ context.Context, token, _ string) (string, error) {
			if token == "good" {
				return operatorSA, nil
			}
			return "", errors.New("token rejected")
		}
	})
	for _, c := range []struct {
		method, path string
		body         any
	}{
		{http.MethodPost, fsGlobsPath, fsGlob("box-a", "op", "/var/log/op*")},
		{http.MethodGet, fsGlobsViewPath, nil},
		{http.MethodGet, fsGlobsAudit, nil},
		{http.MethodDelete, fsGlobsPath + "/0b1e2f3a-4b5c-4d6e-8f70-112233445566", nil},
	} {
		if code, _ := opCall(t, r.e, r.w, c.method, c.path, "good", c.body); code != http.StatusForbidden && code != http.StatusUnauthorized {
			t.Errorf("operator SA %s %s = %d, want 401/403", c.method, c.path, code)
		}
	}
}

// TestFileStreamGlobActAsClone (case C41): an act-as clone of an admin of W
// gets 403 on POST while the admin it clones gets 201. Postgres only (the
// clone store).
func TestFileStreamGlobActAsClone(t *testing.T) {
	r, _ := fsGlobRig(t)
	cs, ok := r.e.st.(dmCloneStore)
	if !ok {
		t.Skip("act-as clone store needs Postgres (SPOOL_TEST_PG_DSN)")
	}
	target := seat(t, r.e, r.w, rbac.Admin)
	now := time.Now().UTC().Truncate(time.Microsecond)
	cl, err := cs.StartClone(context.Background(), store.CloneStart{TenantID: r.w, TargetHum: target, AdminName: "Admin",
		CreatedBy: target, ExpiresAt: now.Add(time.Hour)}, now)
	if err != nil {
		t.Fatal(err)
	}
	if code, b := call(t, r.e, r.w, http.MethodPost, fsGlobsPath, cl.CloneHum, fsGlob("box-a", "clone", "/var/log/c*")); code != http.StatusForbidden {
		t.Errorf("clone POST = %d %v, want 403", code, b)
	}
	if code, b := call(t, r.e, r.w, http.MethodPost, fsGlobsPath, target, fsGlob("box-a", "clone", "/var/log/c*")); code != http.StatusCreated {
		t.Errorf("control: the target POST = %d %v, want 201", code, b)
	}
}

// TestFileStreamGlobCrossTenant (case C42): W2's admin POSTs a glob for
// W's box-b (no box of W2) and for W2's own box-a, which never announced,
// and DELETEs W's glob id: 404 each, the body naming nothing of W, and W's
// glob stays. PLANTED DEFECT: box_id taken from the body unchecked (no
// FileStreamBoxFolders known check): W2's never-announced box-a gets 201.
func TestFileStreamGlobCrossTenant(t *testing.T) {
	r, _ := fsGlobRig(t)
	admin, other := seat(t, r.e, r.w, rbac.Admin), seat(t, r.e, r.w2, rbac.Admin)
	_, body := call(t, r.e, r.w, http.MethodPost, fsGlobsPath, admin, fsGlob("box-b", "app", "/var/log/app*"))
	id, _ := body["id"].(string)
	if id == "" {
		t.Fatalf("seed: %v", body)
	}
	for _, b := range []string{"box-b", "box-a"} {
		code, body := call(t, r.e, r.w2, http.MethodPost, fsGlobsPath, other, fsGlob(b, "x", "/var/log/x*"))
		if code != http.StatusNotFound || strings.Contains(stringOf(body), r.w) {
			t.Errorf("W2 POST for %s = %d %v, want a bare 404", b, code, body)
		}
	}
	code, out := call(t, r.e, r.w2, http.MethodDelete, fsGlobsPath+"/"+id, other, nil)
	if code != http.StatusNotFound || strings.Contains(stringOf(out), r.w) || strings.Contains(stringOf(out), "app") {
		t.Errorf("W2 DELETE of W's glob = %d %v, want a bare 404", code, out)
	}
	if _, b := get(t, r.e, r.w, fsGlobsViewPath, admin); !strings.Contains(string(b), id) {
		t.Errorf("W's glob is gone after W2's DELETE: %s", b)
	}
	if _, b := get(t, r.e, r.w2, fsGlobsViewPath, other); strings.Contains(string(b), id) || strings.Contains(string(b), "/var/log/app*") {
		t.Errorf("W2's list names W's glob: %s", b)
	}
}

func stringOf(m map[string]any) string {
	var sb strings.Builder
	for k, v := range m {
		sb.WriteString(k)
		if s, ok := v.(string); ok {
			sb.WriteString(s)
		}
	}
	return sb.String()
}

// TestFileStreamGlobRefusals (case C43): each bad glob of 3.8.3 is 400
// bad_glob; a bad key 400 bad_key; a taken key 409 glob_key_taken; a 9th
// live glob on one box 409 too_many_globs; a glob outside the announced
// folders, or under a folder the box refused, 400 outside_folders. PLANTED
// DEFECT: CheckFileStreamGlob skipped (accept any string): the bad globs
// are 201.
func TestFileStreamGlobRefusals(t *testing.T) {
	r, _ := fsGlobRig(t)
	admin := seat(t, r.e, r.w, rbac.Admin)
	post := func(key, glob string) (int, map[string]any) {
		return call(t, r.e, r.w, http.MethodPost, fsGlobsPath, admin, fsGlob("box-a", key, glob))
	}
	for _, g := range []string{"var/log/x*", "/var/log/**", "/var/*/x.log", "/var/log/[ab]", "/var/log/{a,b}", "/var/log/../shadow",
		"/var/log/a\x01b", "/var/log/" + strings.Repeat("a", 504)} {
		if code, body := post("k", g); code != http.StatusBadRequest || body["error"] != "bad_glob" {
			t.Errorf("glob %q = %d %v, want 400 bad_glob", g, code, body)
		}
	}
	for _, k := range []string{"", "App", "-a", strings.Repeat("a", 25), "a_b"} {
		if code, body := post(k, "/var/log/x*"); code != http.StatusBadRequest || body["error"] != "bad_key" {
			t.Errorf("key %q = %d %v, want 400 bad_key", k, code, body)
		}
	}
	for _, g := range []string{"/var/lib/x*", "/etc/x*", "/var/logs/x*"} {
		if code, body := post("k", g); code != http.StatusBadRequest || body["error"] != "outside_folders" ||
			!strings.Contains(stringOf(body), "/var/log") {
			t.Errorf("glob %q = %d %v, want 400 outside_folders naming /var/log", g, code, body)
		}
	}
	for i := 0; i < wire.FileStreamGlobsPerBox; i++ {
		if code, body := post("g"+string(rune('a'+i)), "/var/log/nginx/*.log"); code != http.StatusCreated {
			t.Fatalf("live glob %d = %d %v, want 201", i+1, code, body)
		}
	}
	if code, body := post("ga", "/var/log/x*"); code != http.StatusConflict || body["error"] != "glob_key_taken" {
		t.Errorf("a taken key = %d %v, want 409 glob_key_taken", code, body)
	}
	if code, body := post("ninth", "/var/log/x*"); code != http.StatusConflict || body["error"] != "too_many_globs" {
		t.Errorf("a 9th live glob = %d %v, want 409 too_many_globs", code, body)
	}
}

// TestFileStreamGlobBoxLock (case C44): box-a is locked to its owner; an
// admin who is not a lock owner gets 403 box_locked; the lock owner gets
// 201. PLANTED DEFECT: no lock check: the admin's glob is 201.
func TestFileStreamGlobBoxLock(t *testing.T) {
	r, _ := fsGlobRig(t)
	lockOwner, admin := seat(t, r.e, r.w, rbac.Admin), seat(t, r.e, r.w, rbac.Admin)
	lockTo(t, r.e, r.w, r.a, lockOwner)
	if code, body := call(t, r.e, r.w, http.MethodPost, fsGlobsPath, admin, fsGlob("box-a", "app", "/var/log/app*")); code != http.StatusForbidden || body["error"] != "box_locked" {
		t.Errorf("an admin, not a lock owner = %d %v, want 403 box_locked", code, body)
	}
	if code, body := call(t, r.e, r.w, http.MethodPost, fsGlobsPath, lockOwner, fsGlob("box-a", "app", "/var/log/app*")); code != http.StatusCreated {
		t.Errorf("the lock owner = %d %v, want 201", code, body)
	}
	if code, body := call(t, r.e, r.w, http.MethodPost, fsGlobsPath, admin, fsGlob("box-b", "app", "/var/log/app*")); code != http.StatusCreated {
		t.Errorf("CONTROL: the admin on unlocked box-b = %d %v, want 201", code, body)
	}
}

// fsGlobAuditRows is W's audit page as the admin reads it.
func fsGlobAuditRows(t *testing.T, r *fsRig, as string) []map[string]any {
	t.Helper()
	code, body := call(t, r.e, r.w, http.MethodGet, fsGlobsAudit, as, nil)
	if code != http.StatusOK {
		t.Fatalf("audit = %d %v", code, body)
	}
	var out []map[string]any
	for _, x := range body["audit"].([]any) {
		out = append(out, x.(map[string]any))
	}
	return out
}

// TestFileStreamGlobAudit (case C45): an add, a remove and one refused add
// each write one audit row with the actor and the reason code, newest
// first; a second DELETE of the same glob is 404 and writes none. PLANTED
// DEFECT: audit on success only (no AuditFileStreamGlobRefusal): the
// refused add leaves no row.
func TestFileStreamGlobAudit(t *testing.T) {
	r, _ := fsGlobRig(t)
	adder, remover := seat(t, r.e, r.w, rbac.Admin), seat(t, r.e, r.w, rbac.BizOwner)
	_, body := call(t, r.e, r.w, http.MethodPost, fsGlobsPath, adder, fsGlob("box-a", "app", "/var/log/app*"))
	id, _ := body["id"].(string)
	if code := fsDelete(t, r.e, r.w, id, remover); code != http.StatusNoContent {
		t.Fatalf("remove = %d", code)
	}
	if code, _ := call(t, r.e, r.w, http.MethodPost, fsGlobsPath, adder, fsGlob("box-a", "x", "/var/lib/x*")); code != http.StatusBadRequest {
		t.Fatalf("refused add = %d", code)
	}
	rows := fsGlobAuditRows(t, r, adder)
	want := [][3]string{{"refused", adder, "outside_folders"}, {"remove", remover, ""}, {"add", adder, ""}}
	if len(rows) != len(want) {
		t.Fatalf("audit = %d rows %v, want %d", len(rows), rows, len(want))
	}
	for i, w := range want {
		if rows[i]["action"] != w[0] || rows[i]["actor"] != w[1] || rows[i]["reason"] != w[2] || rows[i]["box_id"] != "box-a" {
			t.Errorf("audit row %d = %v, want %v", i, rows[i], w)
		}
	}
	if code := fsDelete(t, r.e, r.w, id, remover); code != http.StatusNotFound {
		t.Errorf("second DELETE = %d, want 404", code)
	}
	if n := len(fsGlobAuditRows(t, r, adder)); n != len(want) {
		t.Errorf("the second DELETE wrote a row: %d, want %d", n, len(want))
	}
	if code, _ := get(t, r.e, r.w, fsGlobsAudit+"?limit=0", adder); code != http.StatusBadRequest {
		t.Errorf("limit=0 = %d, want 400", code)
	}
	if code, b := get(t, r.e, r.w, fsGlobsAudit+"?limit=1&before="+rows[0]["at"].(string), adder); code != http.StatusOK ||
		!strings.Contains(string(b), `"action":"remove"`) || strings.Contains(string(b), `"action":"refused"`) {
		t.Errorf("the page before the newest = %d %s, want the remove row only", code, b)
	}
}

// TestFileStreamGlobPull (case C46): box-a's file_streams_globs pull in W
// returns box-a's live globs in W only: not box-b's, not a removed one, not
// W2's box-a's; a frame naming a box or a tenant is bad_file_stream. Then
// box-a's announce report sets its glob's state on the list. PLANTED
// DEFECT: the pull ignores the session's box (BoxFileStreamGlobs with box
// ""): box-b's glob comes back.
func TestFileStreamGlobPull(t *testing.T) {
	r, b := fsGlobRig(t)
	admin := seat(t, r.e, r.w, rbac.Admin)
	add := func(box, key string) string {
		code, body := call(t, r.e, r.w, http.MethodPost, fsGlobsPath, admin, fsGlob(box, key, "/var/log/"+key+"*.log"))
		if code != http.StatusCreated {
			t.Fatalf("add %s/%s = %d %v", box, key, code, body)
		}
		return body["id"].(string)
	}
	mine, theirs, gone := add("box-a", "mine"), add("box-b", "theirs"), add("box-a", "gone")
	if code := fsDelete(t, r.e, r.w, gone, admin); code != http.StatusNoContent {
		t.Fatal(code)
	}
	ack, err := r.lane(t, r.a, wire.FileStreamsGlobsOp, `{}`)
	if err != nil || ack.Globs == nil || len(*ack.Globs) != 1 || (*ack.Globs)[0].ID != mine || (*ack.Globs)[0].Glob != "/var/log/mine*.log" {
		t.Fatalf("box-a's pull = %+v %v, want only %s", ack.Globs, err, mine)
	}
	if ack, err := r.lane(t, b, wire.FileStreamsGlobsOp, `{}`); err != nil || len(*ack.Globs) != 1 || (*ack.Globs)[0].ID != theirs {
		t.Fatalf("CONTROL: box-b's pull = %+v %v, want %s", ack.Globs, err, theirs)
	}
	if ack, err := r.lane(t, r.a2, wire.FileStreamsGlobsOp, `{}`); err != nil || ack.Globs == nil || len(*ack.Globs) != 0 {
		t.Fatalf("W2's box-a pull = %+v %v, want []", ack.Globs, err)
	}
	for _, raw := range []string{`{"box":"box-b"}`, `{"tenant":"` + r.w2 + `"}`} {
		if _, err := r.lane(t, r.a, wire.FileStreamsGlobsOp, raw); err == nil || !strings.Contains(err.Error(), "bad_file_stream") {
			t.Errorf("a pull naming %s: %v, want bad_file_stream", raw, err)
		}
	}
	report := `[{"id":"` + mine + `","state":"partial","matched":12,"followed":6,"over_cap":6},{"id":"` + theirs + `","state":"refused","reason":"x"}]`
	if _, err := r.lane(t, r.a, wire.FileStreamsAnnounceOp, fsGlobAnnounce(report)); err != nil {
		t.Fatal(err)
	}
	_, list := call(t, r.e, r.w, http.MethodGet, fsGlobsViewPath, admin, nil)
	states := map[string]string{}
	for _, x := range list["globs"].([]any) {
		g := x.(map[string]any)
		states[g["id"].(string)] = g["state"].(string) + "/" + strconv.Itoa(int(g["over_cap"].(float64)))
	}
	if states[mine] != "partial/6" || states[theirs] != "pending/0" || len(list["folders"].([]any)) != 4 {
		t.Errorf("list after box-a's report = %v, want mine partial/6, theirs (box-b's) still pending, 2 folders a box", list)
	}
}

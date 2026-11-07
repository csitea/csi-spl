package hub_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 160 3.10 row B13 (SPL-4979, rdb 0266): a file removed from the view,
// cases C57..C62. Memory always, Postgres with a DSN (hub-pg.tst.sh). Red on
// origin/master before SPL-4979: no DELETE /v1/file-streams/{id} route, so the
// admin's 204 fails (405) and a removed row returns on every announce. Each
// case's planted defect is named on its test; the red runs are in the commit
// body.

func fsRemovePath(id string) string  { return "/v1/file-streams/" + id }
func fsRestorePath(id string) string { return "/v1/file-streams/" + id + "/restore" }

// fsListed is the two lists of GET /v1/view/file-streams.
type fsListed struct {
	Streams []fsListedRow `json:"streams"`
	Removed []fsListedRow `json:"removed"`
}

type fsListedRow struct {
	ID        string  `json:"id"`
	BoxID     string  `json:"box_id"`
	StreamKey string  `json:"stream_key"`
	State     string  `json:"state"`
	RemovedAt *string `json:"removed_at"`
}

func fsList(t *testing.T, r *fsRig, as string) fsListed {
	t.Helper()
	code, body := get(t, r.e, r.w, fileStreamsPath, as)
	if code != http.StatusOK {
		t.Fatalf("list as %s = %d %s", as, code, body)
	}
	var out fsListed
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("list %s: %v", body, err)
	}
	if out.Streams == nil || out.Removed == nil {
		t.Fatalf("list %s: both lists are always present", body)
	}
	return out
}

func fsRemove(t *testing.T, r *fsRig, id, as string) int {
	t.Helper()
	code, _ := call(t, r.e, r.w, http.MethodDelete, fsRemovePath(id), as, nil)
	return code
}

func fsRestore(t *testing.T, r *fsRig, id, as string) int {
	t.Helper()
	code, _ := call(t, r.e, r.w, http.MethodPost, fsRestorePath(id), as, nil)
	return code
}

// fsRowID is the id of (box, key) among W's rows, removed or not.
func fsRowID(t *testing.T, r *fsRig, box, key string) string {
	t.Helper()
	all, err := r.e.st.(store.FileStreamStore).ListFileStreams(context.Background(), r.w)
	if err != nil {
		t.Fatal(err)
	}
	for _, f := range all {
		if f.Box == box && f.StreamKey == key {
			return f.ID
		}
	}
	t.Fatalf("no row %s/%s in %+v", box, key, all)
	return ""
}

// TestFileStreamRemoveSurvivesReannounce (case C57; the brief's red control):
// a cnf row and a glob match, removed, then announced again by the box: both
// stay out of streams, in removed, gone. CONTROL: the same re-announce before
// the remove keeps the row listed, so the announce does reach it; an upsert
// that clears removed_at makes the row return here.
func TestFileStreamRemoveSurvivesReannounce(t *testing.T) {
	r, _ := fsGlobRig(t)
	admin := seat(t, r.e, r.w, rbac.Admin)
	code, g := call(t, r.e, r.w, http.MethodPost, fsGlobsPath, admin, fsGlob("box-a", "web", "/var/log/web*.log"))
	if code != http.StatusCreated {
		t.Fatalf("glob add = %d %v", code, g)
	}
	frame := `{"streams":[{"stream_key":"app","path":"/var/log/app.log","state":"following"},` +
		`{"stream_key":"web-abc123","path":"/var/log/web1.log","state":"following","glob_id":"` + g["id"].(string) + `"}]}`
	announce := func() wire.FileStreamsAckFrame {
		t.Helper()
		ack, err := r.lane(t, r.a, wire.FileStreamsAnnounceOp, frame)
		if err != nil {
			t.Fatal(err)
		}
		return ack
	}
	announce()
	if l := fsList(t, r, admin); len(l.Streams) != 3 || len(l.Removed) != 0 { // box-a's two, box-b's app
		t.Fatalf("CONTROL before the remove = %+v, want 3 rows listed", l)
	}
	for _, key := range []string{"app", "web-abc123"} {
		if code := fsRemove(t, r, fsRowID(t, r, "box-a", key), admin); code != http.StatusNoContent {
			t.Fatalf("remove %s = %d, want 204", key, code)
		}
	}
	for i := 0; i < 2; i++ {
		ack := announce()
		if ack.Streams[0].State != wire.FileStreamGone || ack.Streams[1].State != wire.FileStreamGone {
			t.Fatalf("re-announce %d ack = %+v, want both gone", i, ack.Streams)
		}
		l := fsList(t, r, admin)
		if len(l.Streams) != 1 || l.Streams[0].BoxID != "box-b" || len(l.Removed) != 2 {
			t.Fatalf("re-announce %d: %+v, want only box-b's row listed, 2 removed", i, l)
		}
		for _, x := range l.Removed {
			if x.State != wire.FileStreamGone || x.RemovedAt == nil {
				t.Errorf("removed row = %+v, want gone with removed_at", x)
			}
		}
	}
}

// TestFileStreamRemovePreflight (case C65): the WUI is on another origin, so a
// browser sends OPTIONS before the DELETE and refuses the call if it fails. The
// e2e runs on the mock with no network and cannot see this. CONTROL: the OPTIONS
// routes left out give 405.
func TestFileStreamRemovePreflight(t *testing.T) {
	r := newFSRig(t, store.FileStreamLimits{})
	for _, c := range []struct{ path, method string }{
		{fsRemovePath("00000000-0000-4000-8000-000000000001"), http.MethodDelete},
		{fsRestorePath("00000000-0000-4000-8000-000000000001"), http.MethodPost},
	} {
		req, err := http.NewRequest(http.MethodOptions, r.e.url(r.w)+c.path, nil)
		if err != nil {
			t.Fatal(err)
		}
		req.Header.Set("Origin", wuiOrigin)
		req.Header.Set("Access-Control-Request-Method", c.method)
		req.Header.Set("Access-Control-Request-Headers", "authorization,x-locale")
		resp, err := r.e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNoContent {
			t.Fatalf("OPTIONS %s = %d, want 204", c.path, resp.StatusCode)
		}
		h := resp.Header
		if h.Get("Access-Control-Allow-Origin") != wuiOrigin {
			t.Fatalf("OPTIONS %s: origin not allowed: %v", c.path, h)
		}
		if !strings.Contains(h.Get("Access-Control-Allow-Methods"), c.method) {
			t.Fatalf("OPTIONS %s: %s not allowed: %v", c.path, c.method, h)
		}
		if !strings.Contains(h.Get("Access-Control-Allow-Headers"), "Authorization") {
			t.Fatalf("OPTIONS %s: Authorization not allowed: %v", c.path, h)
		}
	}
}

// TestFileStreamRemoveRBAC (case C58): the owner and an admin get 204 on both
// routes; a member gets 403 and the row stays; a call with no member session
// gets 401/403; another workspace's id, a second remove and a put back of a row
// not removed are 404, and none of them writes an audit row. CONTROL: the gate
// left off the DELETE gives the developer 204.
func TestFileStreamRemoveRBAC(t *testing.T) {
	r, id := fsViewRig(t)
	owner, admin, dev := seat(t, r.e, r.w, rbac.BizOwner), seat(t, r.e, r.w, rbac.Admin), seat(t, r.e, r.w, rbac.Developer)
	if code := fsRemove(t, r, id, dev); code != http.StatusForbidden {
		t.Errorf("developer DELETE = %d, want 403", code)
	}
	if code := fsRemove(t, r, id, ""); code != http.StatusForbidden && code != http.StatusUnauthorized {
		t.Errorf("no member session DELETE = %d, want 401/403", code)
	}
	if l := fsList(t, r, admin); len(l.Streams) != 1 || len(l.Removed) != 0 {
		t.Fatalf("after the refused removes = %+v, want the row listed", l)
	}
	if code := fsRestore(t, r, id, admin); code != http.StatusNotFound {
		t.Errorf("a put back of a row not removed = %d, want 404", code)
	}
	code, _ := call(t, r.e, r.w2, http.MethodDelete, fsRemovePath(id), seat(t, r.e, r.w2, rbac.Admin), nil)
	if code != http.StatusNotFound {
		t.Errorf("another workspace's admin DELETE = %d, want 404", code)
	}
	if rows := fsGlobAuditRows(t, r, admin); len(rows) != 0 {
		t.Fatalf("audit after the refusals = %v, want none", rows)
	}
	if code := fsRemove(t, r, id, admin); code != http.StatusNoContent {
		t.Fatalf("admin DELETE = %d, want 204", code)
	}
	if code := fsRemove(t, r, id, admin); code != http.StatusNotFound {
		t.Errorf("a second DELETE = %d, want 404", code)
	}
	if code := fsRestore(t, r, id, dev); code != http.StatusForbidden {
		t.Errorf("developer restore = %d, want 403", code)
	}
	if code := fsRestore(t, r, id, owner); code != http.StatusNoContent {
		t.Fatalf("owner restore = %d, want 204", code)
	}
	if code := fsRemove(t, r, id, owner); code != http.StatusNoContent {
		t.Fatalf("owner DELETE = %d, want 204", code)
	}
	rows := fsGlobAuditRows(t, r, admin)
	actions := []string{}
	for _, a := range rows {
		actions = append(actions, a["action"].(string))
	}
	if !slices.Equal(actions, []string{"file_remove", "file_restore", "file_remove"}) {
		t.Fatalf("audit actions = %v, newest first", actions)
	}
	if rows[0]["key"] != "app" || rows[0]["glob"] != "/var/log/app.log" || rows[0]["actor"] != owner {
		t.Errorf("audit row = %v", rows[0])
	}
}

// TestFileStreamRemoveActAsClone (case C58, Postgres): an act-as clone of an
// admin is 403 on both routes. CONTROL: its target gets 204.
func TestFileStreamRemoveActAsClone(t *testing.T) {
	r, id := fsViewRig(t)
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
	if code := fsRemove(t, r, id, cl.CloneHum); code != http.StatusForbidden {
		t.Errorf("clone DELETE = %d, want 403", code)
	}
	if code := fsRemove(t, r, id, target); code != http.StatusNoContent {
		t.Fatalf("CONTROL: the target DELETE = %d, want 204", code)
	}
	if code := fsRestore(t, r, id, cl.CloneHum); code != http.StatusForbidden {
		t.Errorf("clone restore = %d, want 403", code)
	}
}

// TestFileStreamRemoveOperatorSA (case C58): the operator service account's
// Bearer token is 401/403 on both routes. CONTROL: an operator bypass on the
// gate answers it 204.
func TestFileStreamRemoveOperatorSA(t *testing.T) {
	op := newTenantID("op")
	r, id := fsViewRig(t, func(o *hub.Options) {
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
	for _, x := range [][2]string{{http.MethodDelete, fsRemovePath(id)}, {http.MethodPost, fsRestorePath(id)}} {
		if code, _ := opCall(t, r.e, r.w, x[0], x[1], "good", nil); code != http.StatusForbidden && code != http.StatusUnauthorized {
			t.Errorf("operator SA %s %s = %d, want 401/403", x[0], x[1], code)
		}
	}
}

// TestFileStreamRemovePushAcked (case C59; item 2 of the plan, an older follower
// that never reads removed_keys): its push of a removed key is acked to its
// highest seq, so nothing stays in its queue, and stores nothing; the stored
// lines stay readable by id; after a put back and an announce the same row is
// following and stores again. CONTROL: a 403 refused here is what a follower
// keeps queued (ctl:keep-on-fail).
func TestFileStreamRemovePushAcked(t *testing.T) {
	r, id := fsViewRig(t) // 5 lines
	admin := seat(t, r.e, r.w, rbac.Admin)
	if code := fsRemove(t, r, id, admin); code != http.StatusNoContent {
		t.Fatal(code)
	}
	if _, err := r.lane(t, r.a, wire.FileStreamsAnnounceOp, fsAnnounce("app")); err != nil {
		t.Fatal(err)
	}
	ack, err := r.lane(t, r.a, wire.FileStreamsPushOp, fsPushBody("app", 6, 3, time.Now()))
	if err != nil || ack.Type != "ack" || ack.AckedSeq != 8 || ack.Inserted != 0 {
		t.Fatalf("the older follower's push = %+v %v, want an ack to 8, 0 stored", ack, err)
	}
	code, body := get(t, r.e, r.w, fsLinesPath(id, "?after=0"), admin)
	if seqs := fsSeqs(t, body); code != http.StatusOK || !fsEq(seqs, 1, 2, 3, 4, 5) {
		t.Fatalf("lines of the removed row = %d %v, want 1..5, readable by id", code, seqs)
	}
	if code := fsRestore(t, r, id, admin); code != http.StatusNoContent {
		t.Fatal(code)
	}
	if _, err := r.lane(t, r.a, wire.FileStreamsAnnounceOp, fsAnnounce("app")); err != nil {
		t.Fatal(err)
	}
	l := fsList(t, r, admin)
	if len(l.Streams) != 1 || l.Streams[0].ID != id || l.Streams[0].State != wire.FileStreamFollowing || len(l.Removed) != 0 {
		t.Fatalf("after the put back and an announce = %+v, want following on row %s", l, id)
	}
	if ack, err := r.lane(t, r.a, wire.FileStreamsPushOp, fsPushBody("app", 9, 1, time.Now())); err != nil || ack.Inserted != 1 {
		t.Fatalf("a push after the put back = %+v %v, want 1 stored", ack, err)
	}
}

// TestFileStreamRemoveOneBox (case C60): the same key on box-a and box-b:
// removing box-a's leaves box-b's listed and storing; only box-a's pull names
// the key, and W2's box-a, the same box name in another workspace, has none.
// CONTROL: a removal keyed on stream_key alone takes box-b's row too.
func TestFileStreamRemoveOneBox(t *testing.T) {
	r, b := fsGlobRig(t)
	if _, err := r.lane(t, r.a2, wire.FileStreamsAnnounceOp, fsGlobAnnounce("")); err != nil {
		t.Fatal(err)
	}
	admin := seat(t, r.e, r.w, rbac.Admin)
	if code := fsRemove(t, r, fsRowID(t, r, "box-a", "app"), admin); code != http.StatusNoContent {
		t.Fatal(code)
	}
	if l := fsList(t, r, admin); len(l.Streams) != 1 || l.Streams[0].BoxID != "box-b" || len(l.Removed) != 1 || l.Removed[0].BoxID != "box-a" {
		t.Fatalf("list = %+v, want box-b's row, box-a's removed", l)
	}
	for _, x := range []struct {
		name string
		b    *box
		want []string
	}{{"box-a", r.a, []string{"app"}}, {"box-b", b, []string{}}, {"W2's box-a", r.a2, []string{}}} {
		ack, err := r.lane(t, x.b, wire.FileStreamsGlobsOp, `{}`)
		if err != nil || ack.RemovedKeys == nil || !slices.Equal(*ack.RemovedKeys, x.want) {
			t.Errorf("%s's pull: %+v %v, want removed_keys %v", x.name, ack.RemovedKeys, err, x.want)
		}
	}
	if ack, err := r.lane(t, b, wire.FileStreamsPushOp, fsPushBody("app", 1, 2, time.Now())); err != nil || ack.Inserted != 2 {
		t.Fatalf("box-b's push = %+v %v, want 2 stored", ack, err)
	}
}

// TestFileStreamRemoveBoxLock (case C62): on a locked box an admin who is no
// lock owner removes a row (D7) but gets 403 box_locked on the put back, with
// one refused audit row, and the row stays removed; the lock owner puts it back.
// CONTROL: the lock skipped on restore gives the admin 204.
func TestFileStreamRemoveBoxLock(t *testing.T) {
	r, _ := fsGlobRig(t)
	lockOwner, admin := seat(t, r.e, r.w, rbac.Admin), seat(t, r.e, r.w, rbac.Admin)
	lockTo(t, r.e, r.w, r.a, lockOwner)
	id := fsRowID(t, r, "box-a", "app")
	if code := fsRemove(t, r, id, admin); code != http.StatusNoContent {
		t.Fatalf("an admin's remove on a locked box = %d, want 204", code)
	}
	code, body := call(t, r.e, r.w, http.MethodPost, fsRestorePath(id), admin, nil)
	if code != http.StatusForbidden || body["error"] != "box_locked" {
		t.Fatalf("an admin's put back = %d %v, want 403 box_locked", code, body)
	}
	if l := fsList(t, r, lockOwner); len(l.Removed) != 1 {
		t.Fatalf("after the refused put back = %+v, want the row still removed", l)
	}
	rows := fsGlobAuditRows(t, r, lockOwner)
	if rows[0]["action"] != "refused" || rows[0]["reason"] != "box_locked" || rows[0]["key"] != "app" {
		t.Errorf("newest audit row = %v, want refused box_locked", rows[0])
	}
	if code := fsRestore(t, r, id, lockOwner); code != http.StatusNoContent {
		t.Fatalf("the lock owner's put back = %d, want 204", code)
	}
}

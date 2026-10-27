package hub_test

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 160 row B3 (SPL-3888): the File streams tab's reads and their gate.
// Red on origin/master before B3: no /v1/view/file-streams route (404 for
// every caller, so the owner's 200 below fails).

const fileStreamsPath = "/v1/view/file-streams"

// fsViewRig is fsRig with box-a of W streaming 5 lines into "app".
func fsViewRig(t *testing.T, mut ...func(*hub.Options)) (*fsRig, string) {
	t.Helper()
	r := newFSRig(t, store.FileStreamLimits{}, mut...)
	if _, err := r.lane(t, r.a, wire.FileStreamsAnnounceOp, fsAnnounce("app")); err != nil {
		t.Fatal(err)
	}
	if _, err := r.lane(t, r.a, wire.FileStreamsPushOp, fsPushBody("app", 1, 5, time.Now())); err != nil {
		t.Fatal(err)
	}
	all, err := r.e.st.(store.FileStreamStore).ListFileStreams(context.Background(), r.w)
	if err != nil || len(all) != 1 {
		t.Fatalf("seed: %+v %v", all, err)
	}
	return r, all[0].ID
}

func fsLinesPath(id, q string) string { return fileStreamsPath + "/" + id + "/lines" + q }

func fsSeqs(t *testing.T, body []byte) []int64 {
	t.Helper()
	var out struct {
		Lines []struct {
			Seq int64 `json:"seq"`
		} `json:"lines"`
	}
	if err := json.Unmarshal(body, &out); err != nil {
		t.Fatalf("lines body %s: %v", body, err)
	}
	seqs := make([]int64, len(out.Lines))
	for i, l := range out.Lines {
		seqs[i] = l.Seq
	}
	return seqs
}

func fsEq(a []int64, b ...int64) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// TestFileStreamsViewRBAC (cases C12, C28, C29): an owner or admin of W
// reads all three routes; a member (developer) gets 403 on each, so does a
// call with no member session (what the operator service account and a box
// have on a view route). CONTROL: a membership-only gate gives the
// developer 200.
func TestFileStreamsViewRBAC(t *testing.T) {
	r, id := fsViewRig(t)
	admin, dev := seat(t, r.e, r.w, rbac.Admin), seat(t, r.e, r.w, rbac.Developer)
	paths := []string{fileStreamsPath, fsLinesPath(id, "?after=0"), fsLinesPath(id, "?before=5")}
	for _, p := range paths {
		if code, body := get(t, r.e, r.w, p, admin); code != http.StatusOK {
			t.Errorf("admin GET %s = %d %s, want 200", p, code, body)
		}
		if code, _ := get(t, r.e, r.w, p, dev); code != http.StatusForbidden {
			t.Errorf("developer GET %s = %d, want 403", p, code)
		}
		if code, _ := get(t, r.e, r.w, p, ""); code != http.StatusForbidden && code != http.StatusUnauthorized {
			t.Errorf("no member session GET %s = %d, want 401/403", p, code)
		}
	}
	_, body := get(t, r.e, r.w, fileStreamsPath, admin)
	if !strings.Contains(string(body), `"stream_key":"app"`) || !strings.Contains(string(body), `"box_id":"box-a"`) {
		t.Fatalf("list = %s", body)
	}
}

// TestFileStreamsViewLines: after, before and the last lines, oldest first,
// with limit; a bad query is 400.
func TestFileStreamsViewLines(t *testing.T) {
	r, id := fsViewRig(t)
	admin := seat(t, r.e, r.w, rbac.Admin)
	for q, want := range map[string][]int64{
		"?after=2":          {3, 4, 5},
		"?after=2&limit=2":  {3, 4},
		"?before=4":         {1, 2, 3},
		"?before=5&limit=2": {3, 4},
		"?limit=2":          {4, 5},
		"":                  {1, 2, 3, 4, 5},
	} {
		code, body := get(t, r.e, r.w, fsLinesPath(id, q), admin)
		if got := fsSeqs(t, body); code != http.StatusOK || !fsEq(got, want...) {
			t.Errorf("lines%s = %d %v, want %v", q, code, got, want)
		}
	}
	for _, q := range []string{"?after=-1", "?before=0", "?limit=0", "?after=1&before=3", "?after=x"} {
		if code, _ := get(t, r.e, r.w, fsLinesPath(id, q), admin); code != http.StatusBadRequest {
			t.Errorf("lines%s = %d, want 400", q, code)
		}
	}
}

// TestFileStreamsViewCrossTenant (case C13): W2's owner asks for W's stream
// id: 404, the body names nothing of W, and W2's list is empty. CONTROL: a
// read by id without the tenant answers W's lines.
func TestFileStreamsViewCrossTenant(t *testing.T) {
	r, id := fsViewRig(t)
	other := seat(t, r.e, r.w2, rbac.Admin)
	code, body := get(t, r.e, r.w2, fsLinesPath(id, ""), other)
	if code != http.StatusNotFound || strings.Contains(string(body), "line ") || strings.Contains(string(body), r.w) {
		t.Fatalf("W2 reads W's stream = %d %s, want a bare 404", code, body)
	}
	if code, body := get(t, r.e, r.w2, fileStreamsPath, other); code != http.StatusOK || strings.Contains(string(body), "app") {
		t.Fatalf("W2's list = %d %s, want none of W's", code, body)
	}
}

// TestFileStreamsViewActAsClone (case C27): an act-as clone of an owner of
// W gets 403 on all three routes while the owner it clones reads them.
// Postgres only (the clone store). CONTROL: the gate on TenantOwner || admin
// alone lets the clone, seated with the target's role, read.
func TestFileStreamsViewActAsClone(t *testing.T) {
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
	for _, p := range []string{fileStreamsPath, fsLinesPath(id, "?after=0"), fsLinesPath(id, "?before=5")} {
		if code, _ := get(t, r.e, r.w, p, target); code != http.StatusOK {
			t.Errorf("control: the target GET %s = %d, want 200", p, code)
		}
		if code, _ := get(t, r.e, r.w, p, cl.CloneHum); code != http.StatusForbidden {
			t.Errorf("clone GET %s = %d, want 403", p, code)
		}
	}
}

// TestFileStreamsViewOperatorSA (case C28): the operator service account's
// Bearer token on the read routes is 401/403. CONTROL: an operator bypass
// on the gate answers it 200.
func TestFileStreamsViewOperatorSA(t *testing.T) {
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
	for _, p := range []string{fileStreamsPath, fsLinesPath(id, "?after=0")} {
		if code, _ := opCall(t, r.e, r.w, http.MethodGet, p, "good", nil); code != http.StatusForbidden && code != http.StatusUnauthorized {
			t.Errorf("operator SA GET %s = %d, want 401/403", p, code)
		}
	}
}

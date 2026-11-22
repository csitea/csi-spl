package hub_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// switchDocs is a docs store whose list fails while down is set: a bucket
// that does not exist (spec 158 10.1 U4, the 503 of M16).
type switchDocs struct {
	blob.Dir
	down *atomic.Bool
}

func (d switchDocs) List(ctx context.Context, prefix string, fn func(string, time.Time) error) error {
	if d.down.Load() {
		return errBucketGone
	}
	return d.Dir.List(ctx, prefix, fn)
}

// readinessRig is an operator workspace with its admin, a fresh workspace w,
// and this hub's box-wui key.
type readinessRig struct {
	e         *env
	op, admin string
	w         string
	wui       ed25519.PrivateKey
	docsDown  *atomic.Bool
	opTS      time.Time
}

func newReadinessRig(t *testing.T) *readinessRig {
	t.Helper()
	g := &readinessRig{op: newTenantID("op"), w: newTenantID("rw"), docsDown: &atomic.Bool{}, opTS: time.Now()}
	_, g.wui, _ = ed25519.GenerateKey(nil)
	root := t.TempDir()
	docs, err := hub.NewWorkspaceDocs(filepath.Join(root, "{tenant}"), func(_ context.Context, dir string) (blob.Store, error) {
		return switchDocs{blob.Dir{Root: dir}, g.docsDown}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	g.e = rbacEnv(t, func(o *hub.Options) { o.OperatorTenant, o.WorkspaceDocs, o.WUIKey = g.op, docs, g.wui })
	for _, id := range []string{g.op, g.w} {
		pub, _, _ := ed25519.GenerateKey(nil)
		if err := g.e.st.CreateTenant(context.Background(), store.Tenant{ID: id, RootPubKey: pub}); err != nil {
			t.Fatal(err)
		}
	}
	g.admin = seat(t, g.e, g.op, rbac.Admin)
	return g
}

// steps reads the readiness of w as the operator admin, by step name.
func (g *readinessRig) steps(t *testing.T) map[string]map[string]any {
	t.Helper()
	code, body := call(t, g.e, g.op, http.MethodGet, opPath+"/"+g.w+"/readiness", g.admin, nil)
	list, _ := body["steps"].([]any)
	if code != http.StatusOK || body["workspace"] != g.w || len(list) != 6 {
		t.Fatalf("readiness = %d %v", code, body)
	}
	out := map[string]map[string]any{}
	var order []string
	for _, x := range list {
		s := x.(map[string]any)
		out[s["step"].(string)] = s
		order = append(order, s["step"].(string))
	}
	want := []string{"invite", "host", "docs", "pin", "seats", "first_answer"}
	for i := range want {
		if order[i] != want[i] {
			t.Fatalf("step order = %v, want %v", order, want)
		}
	}
	return out
}

// want checks one step's state and, when given, its row.
func (g *readinessRig) want(t *testing.T, step, state, row string) map[string]any {
	t.Helper()
	s := g.steps(t)[step]
	if s["state"] != state || (row != "" && s["row"] != row) || (row == "" && s["row"] != nil) {
		t.Fatalf("%s = %v, want state %s row %q", step, s, state, row)
	}
	return s
}

func (g *readinessRig) pin(t *testing.T, box string, pub ed25519.PublicKey, force bool) {
	t.Helper()
	g.opTS = g.opTS.Add(time.Second)
	if err := g.e.st.PutPin(context.Background(), g.w, box, pub, force, g.opTS, g.opTS); err != nil {
		t.Fatal(err)
	}
}

// post stores one message of task in w from box.
func (g *readinessRig) post(t *testing.T, task, box, from string, at time.Time) {
	t.Helper()
	g.postSig(t, task, box, from, "", at)
}

// postSig stores one message of task in w from box with env_sig sig.
func (g *readinessRig) postSig(t *testing.T, task, box, from, sig string, at time.Time) {
	t.Helper()
	id := uuidV4()
	if _, err := g.e.st.InsertMessage(context.Background(), store.Message{TenantID: g.w, MsgID: id, TaskID: task,
		Channel: "lobby", IsParent: 1, TS: at, FromBox: box, FromID: from, ToBox: "box-x", ToID: "c-001", Kind: "note",
		Body: "hello " + id, Files: []byte(`[]`), Msg: []byte(`{"v":1}`), EnvSig: sig,
		Env:        []byte(`{"from_box":"` + box + `","msg_id":"` + id + `"}`),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}); err != nil {
		t.Fatal(err)
	}
}

// Spec 158 10.8 row V1 (SPL-5027): GET /v1/operator/workspaces/{id}/readiness
// is the operator admin's only. A workspace admin (of the target itself),
// every other role of the operator workspace and the anonymous get 403
// operator.workspaces; a missing workspace is 404. CONTROL: the operator
// admin reads it, so the 403s are the role rule, not a missing route.
func TestOperatorReadinessRBAC(t *testing.T) {
	e, op, other, who, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	path := opPath + "/" + other + "/readiness"
	type caller struct{ name, tenant, hum string }
	denied := []caller{{"workspace admin of the target", other, whoOther[rbac.Admin]}, {"anonymous", op, ""}}
	for _, r := range rbac.RoleIDs {
		if r != rbac.Admin {
			denied = append(denied, caller{"operator " + r, op, who[r]})
		}
	}
	for _, c := range denied {
		if code, body := call(t, e, c.tenant, http.MethodGet, path, c.hum, nil); code != http.StatusForbidden || body["permission"] != "operator.workspaces" {
			t.Errorf("%s: GET %s = %d %v, want 403 operator.workspaces", c.name, path, code, body)
		}
	}
	if code, body := call(t, e, op, http.MethodGet, opPath+"/"+newTenantID("no")+"/readiness", who[rbac.Admin], nil); code != http.StatusNotFound || body["error"] != "not_found" {
		t.Fatalf("missing workspace = %d %v, want 404 not_found", code, body)
	}
	code, body := call(t, e, op, http.MethodGet, path, who[rbac.Admin], nil)
	if steps, _ := body["steps"].([]any); code != http.StatusOK || len(steps) != 6 {
		t.Fatalf("CONTROL operator admin = %d %v", code, body)
	}
	// operatorEnv seated every role of other by an accepted invite.
	if s := body["steps"].([]any)[0].(map[string]any); s["state"] != "accepted" || s["u"] != "U2" {
		t.Fatalf("invite of a seated workspace = %v", s)
	}
}

// Each state of the invite step (U1, U2): none stored, stored and not
// mailed, mailed, accepted.
func TestOperatorReadinessInvite(t *testing.T) {
	g := newReadinessRig(t)
	ctx := context.Background()
	if s := g.want(t, "invite", "not_sent", ""); s["detail"] != "no invite stored" {
		t.Fatalf("fresh: %v", s)
	}
	now := time.Now()
	email := uuidV4()[:8] + "@example.com"
	if err := g.e.st.(store.Humans).PutInvite(ctx, store.Invite{TenantID: g.w, Email: email, Role: rbac.Admin,
		InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
		t.Fatal(err)
	}
	if s := g.want(t, "invite", "not_sent", ""); s["detail"] != "stored, never mailed" {
		t.Fatalf("stored: %v", s)
	}
	if c, err := g.e.st.(store.InviteMails).ClaimInviteMail(ctx, g.w, email, store.InviteMailLimits{MaxSends: 5}, now); err != nil || c.Outcome != store.InviteMailClaimed {
		t.Fatalf("claim: %+v %v", c, err)
	}
	if s := g.want(t, "invite", "sent", ""); s["at"] == nil || s["u"] != "U1" {
		t.Fatalf("mailed: %v", s)
	}
	if _, err := g.e.st.(store.Humans).Admit(ctx, store.Identity{Provider: "google", Subject: "s-" + email, Email: email}, g.w, store.AdmitPolicy{}, now); err != nil {
		t.Fatal(err)
	}
	if s := g.want(t, "invite", "accepted", ""); s["u"] != "U2" {
		t.Fatalf("accepted: %v", s)
	}
}

// Each state of the host (U3) and docs (U4) steps: a pending host with no
// reason names row H3, one with its reason does not; failed keeps its
// reason; docs waits for the host, then answers ok or unavailable.
func TestOperatorReadinessHostDocs(t *testing.T) {
	g := newReadinessRig(t)
	ctx := context.Background()
	g.want(t, "host", "waiting", "H3")
	g.want(t, "docs", "waiting", "")
	set := func(status, detail string) {
		t.Helper()
		if err := g.e.st.SetTenantHost(ctx, g.w, status, detail, time.Now()); err != nil {
			t.Fatal(err)
		}
	}
	set(store.HostPending, "placeholder reserved 2026-11-22T20:00:00Z")
	if s := g.want(t, "host", "waiting", ""); s["detail"] != "placeholder reserved 2026-11-22T20:00:00Z" {
		t.Fatalf("waiting with reason: %v", s)
	}
	set(store.HostFailed, "apply failed")
	if s := g.want(t, "host", "failed", ""); s["detail"] != "apply failed" || s["at"] == nil {
		t.Fatalf("failed: %v", s)
	}
	g.want(t, "docs", "waiting", "")
	set(store.HostReady, "")
	g.want(t, "host", "ready", "")
	g.want(t, "docs", "ok", "")
	g.docsDown.Store(true)
	g.want(t, "docs", "unavailable", "")
	set(store.HostRemoving, "")
	g.want(t, "host", "removing", "")
}

// Each state of the pin step (U5): missing, other key, revoked, then on the
// hub's key no_post, unsigned and ok. U5 is the signed post of spec 158 10.1
// (SPL-5027, g-773's send-back): the hub's key alone is no_post, never ok,
// and a signed post under a key that is not the hub's stays other_key.
func TestOperatorReadinessPin(t *testing.T) {
	g := newReadinessRig(t)
	g.want(t, "pin", "missing", "")
	foreign, _, _ := ed25519.GenerateKey(nil)
	g.pin(t, hub.WUIBox, foreign, false)
	g.want(t, "pin", "other_key", "")
	g.opTS = g.opTS.Add(time.Second)
	if err := g.e.st.RevokePin(context.Background(), g.w, hub.WUIBox, g.opTS, g.opTS); err != nil {
		t.Fatal(err)
	}
	g.want(t, "pin", "revoked", "")
	g.pin(t, hub.WUIBox, g.wui.Public().(ed25519.PublicKey), true)
	g.want(t, "pin", "no_post", "")
	at := time.Now().UTC().Truncate(time.Second).Add(-time.Minute)
	g.post(t, uuidV4(), "box-x", "c-002", at.Add(-time.Minute)) // an agent's own signed-or-not post is no member post
	g.want(t, "pin", "no_post", "")
	g.post(t, uuidV4(), hub.WUIBox, "HUM-1", at)
	g.want(t, "pin", "unsigned", "")
	g.postSig(t, uuidV4(), hub.WUIBox, "HUM-1", "sig", at.Add(time.Second))
	if s := g.want(t, "pin", "ok", ""); s["at"] != at.Add(time.Second).Format(time.RFC3339) {
		t.Fatalf("signed at: %v", s)
	}
	g.pin(t, hub.WUIBox, foreign, true)
	g.want(t, "pin", "other_key", "")
}

// Each state of the seats step (U6): no desk box listed (unknown, row S2),
// listed and not pinned here, pinned with no agent, an agent in the roster.
// The desk list is the hub's one table (Postgres: shared by every test), so
// unknown is asserted only while it reads empty around the call.
func TestOperatorReadinessSeats(t *testing.T) {
	g := newReadinessRig(t)
	ctx := context.Background()
	fd := g.e.st.(store.FleetDeskBoxes)
	before, _ := fd.ListFleetDeskBoxes(ctx)
	s := g.steps(t)["seats"]
	after, _ := fd.ListFleetDeskBoxes(ctx)
	if len(before) == 0 && len(after) == 0 && (s["state"] != "unknown" || s["row"] != "S2") {
		t.Fatalf("no desk listed: %v", s)
	}
	box := "rd-" + uuidV4()[:8]
	if _, _, err := fd.PutFleetDeskBox(ctx, box, "test"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = fd.DeleteFleetDeskBox(context.Background(), box) })
	g.want(t, "seats", "waiting", "")
	pub, _, _ := ed25519.GenerateKey(nil)
	g.pin(t, box, pub, false)
	if s := g.want(t, "seats", "waiting", ""); s["detail"] == nil || !strings.Contains(s["detail"].(string), "0 agents") {
		t.Fatalf("pinned, no agent: %v", s)
	}
	if err := g.e.st.SetRoster(ctx, g.w, box, []string{"c-001"}, time.Now()); err != nil {
		t.Fatal(err)
	}
	if s := g.want(t, "seats", "seated", ""); !strings.Contains(s["detail"].(string), "1 agents") {
		t.Fatalf("seated: %v", s)
	}
}

// Each state of the first answer (U6): no member post, a member post with
// no answer (since its time), then an agent's message after it.
func TestOperatorReadinessFirstAnswer(t *testing.T) {
	g := newReadinessRig(t)
	g.want(t, "first_answer", "no_post", "")
	task := uuidV4()
	at := time.Now().UTC().Truncate(time.Second).Add(-time.Minute)
	g.post(t, uuidV4(), "box-x", "c-002", at.Add(-time.Minute)) // an agent's own topic: no member post
	g.want(t, "first_answer", "no_post", "")
	g.post(t, task, hub.WUIBox, "HUM-1", at)
	if s := g.want(t, "first_answer", "waiting", ""); s["at"] != at.Format(time.RFC3339) {
		t.Fatalf("waiting since: %v, want at %s", s, at.Format(time.RFC3339))
	}
	g.post(t, task, "box-x", "c-001", at.Add(30*time.Second))
	if s := g.want(t, "first_answer", "answered", ""); s["at"] != at.Add(30*time.Second).Format(time.RFC3339) {
		t.Fatalf("answered: %v", s)
	}
}

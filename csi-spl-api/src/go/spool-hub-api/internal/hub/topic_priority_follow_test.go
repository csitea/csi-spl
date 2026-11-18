package hub_test

import (
	"context"
	"crypto/ed25519"
	"encoding/json"
	"fmt"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// Spec 150 section 3.4 item 4 (SPL-4813; owner HUM-10, csitea b0f50875,
// msgs ee3d6efc and f061e485): the discussion's priority is the source. An
// issue follows the highest priority SET on its linked discussions (the
// workspace's default discussion does not count), and a lane shows the
// highest of its issues, so a lane on a priority 1 discussion shows 1.
// Memory, and Postgres under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full).

// issuePrio is one issue's stored priority, read through the hub.
func issuePrio(t *testing.T, e *env, tid, hum, key string) int {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues/"+key, hum, nil)
	if code != http.StatusOK {
		t.Fatalf("GET issue %s: %d %v", key, code, out)
	}
	p, _ := issueOf(t, out)["priority"].(float64)
	return int(p)
}

// relayCopy stores in tid a post of another workspace's topic task, as the
// fleet relay leaves one (prd: t1 holds 2 posts of csitea's 269d405d, so a
// t1 issue may link it).
func relayCopy(t *testing.T, e *env, tid, task string) {
	t.Helper()
	at := time.Now().UTC()
	m := store.Message{TenantID: tid, MsgID: uid.New(), TaskID: task, Channel: store.ChannelLobby, TS: at,
		FromBox: "box-wui", FromID: "HUM-1", ToBox: "box-wui", ToID: "ALL-0", Kind: "note", Body: "relayed",
		Files: []byte(`[]`), Msg: []byte(`{"v":1}`), EnvSig: "sig", Env: []byte(`{"env":1}`),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour), IsParent: 1}
	if _, err := e.st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
}

// C150-F1: the owner sets a discussion's priority AFTER its lane and issue
// exist; the PUT moves the issue and the lane shows it at once. An issue on
// the default discussion only, and a lane on an unset discussion, keep their
// own. RED CONTROL (master 77463637a): the lane stays at 5.
func TestTopicPriorityFollowsToIssuesAndLanes(t *testing.T) {
	r := newFleetTokensRig(t)
	talk, other := uid.New(), uid.New()
	lobbyTopic(t, r.e, r.op, talk, "## Prio follows\n\nrow")
	lobbyTopic(t, r.e, r.op, other, "## Unset\n\nrow")
	k := issueWithPrio(t, r.e, r.op, r.admin, "born of talk", talk, 5)
	issueWithPrio(t, r.e, r.op, r.admin, "born of other", other, 4)
	kDefault := issueWithPrio(t, r.e, r.op, r.admin, "default only", store.IssueDiscussionDefault(r.op), 5)
	laneAt(t, r, "c-651", r.opBox.id, talk, "", time.Now().Add(-time.Minute))
	laneAt(t, r, "c-652", r.opBox.id, other, "", time.Now().Add(-2*time.Minute))
	if p, _ := prioOf(t, prioLanes(t, r.e, r.ws, r.op, fleetLanesPath, r.admin), "c-651"); p != 5 {
		t.Fatalf("before: lane prio %d, want 5", p)
	}

	if code, out := putPriority(t, r.e, r.op, talk, r.admin, map[string]any{"priority": 1}); code != http.StatusOK {
		t.Fatalf("PUT priority: %d %v", code, out)
	}
	ls := prioLanes(t, r.e, r.ws, r.op, fleetLanesPath, r.admin)
	if p, is := prioOf(t, ls, "c-651"); p != 1 || is != k+" 1" {
		t.Errorf("C150-F1 lane on the priority 1 discussion: prio %d, issues %q; want 1 and %s 1", p, is, k)
	}
	if p, _ := prioOf(t, ls, "c-652"); p != 4 {
		t.Errorf("C150-F1 lane on an unset discussion: prio %d, want its issue's 4", p)
	}
	if got := issuePrio(t, r.e, r.op, r.admin, kDefault); got != 5 {
		t.Errorf("C150-F1 issue on the default discussion only: prio %d, want its own 5", got)
	}

	// C150-F3: the fleet's lane issue sits in the operator workspace and
	// links the owner's topic in another workspace (csitea 269d405d, t1
	// SPL-4637): a PUT there by an owner of the operator workspace moves it
	// too; one by that workspace's admin does not (SPL-5933). RED CONTROL: a
	// run that reads the operator workspace's own priorities only leaves it
	// at 5.
	far := uid.New()
	lobbyTopic(t, r.e, r.other, far, "## Far\n\nrow")
	relayCopy(t, r.e, r.op, far)
	kFar := issueWithPrio(t, r.e, r.op, r.admin, "lane issue on a far topic", far, 5)
	laneAt(t, r, "c-653", r.opBox.id, far, kFar, time.Now().Add(-3*time.Minute))
	if code, out := putPriority(t, r.e, r.other, far, r.otherA, map[string]any{"priority": 4}); code != http.StatusOK {
		t.Fatalf("PUT far priority by its admin: %d %v", code, out)
	}
	if got := issuePrio(t, r.e, r.op, r.admin, kFar); got != 5 {
		t.Errorf("SPL-5933 operator issue after a set by the far workspace's admin: prio %d, want its own 5", got)
	}
	owner := opOwnerSeat(t, r)
	if code, out := putPriority(t, r.e, r.other, far, owner, map[string]any{"priority": 2}); code != http.StatusOK {
		t.Fatalf("PUT far priority: %d %v", code, out)
	}
	if got := issuePrio(t, r.e, r.op, r.admin, kFar); got != 2 {
		t.Errorf("C150-F3 operator issue on another workspace's topic: prio %d, want 2", got)
	}
	if p, _ := prioOf(t, prioLanes(t, r.e, r.ws, r.op, fleetLanesPath, r.admin), "c-653"); p != 2 {
		t.Errorf("C150-F3 its lane: prio %d, want 2", p)
	}

	// A later change follows too: the owner triages on discussions.
	if code, out := putPriority(t, r.e, r.op, talk, r.admin, map[string]any{"priority": 3}); code != http.StatusOK {
		t.Fatalf("PUT priority 3: %d %v", code, out)
	}
	if got := issuePrio(t, r.e, r.op, r.admin, k); got != 3 {
		t.Errorf("C150-F1 second set: issue prio %d, want 3", got)
	}
}

// opOwnerSeat admits one human as the business owner of the rig's operator
// workspace and as an admin of its other workspace (the t1 owner, who is a
// member of csitea too): the setter whose far sets order the operator issues
// (SPL-5933).
func opOwnerSeat(t *testing.T, r *fleetTokensRig) string {
	t.Helper()
	h := r.e.st.(store.Humans)
	id := store.Identity{Provider: "google", Subject: "s-" + uid.New(), Email: uid.New()[:10] + "@example.com"}
	hum := ""
	for _, w := range []struct{ tid, role string }{{r.op, rbac.BizOwner}, {r.other, rbac.Admin}} {
		now := time.Now()
		if err := h.PutInvite(context.Background(), store.Invite{TenantID: w.tid, Email: id.Email, Role: w.role,
			InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
			t.Fatal(err)
		}
		got, err := h.Admit(context.Background(), id, w.tid, store.AdmitPolicy{}, now)
		if err != nil {
			t.Fatal(err)
		}
		if hum != "" && got != hum {
			t.Fatalf("one identity admitted as %s and %s", hum, got)
		}
		hum = got
	}
	return hum
}

// prioSync runs the agent issue op prio-sync (the 5-min cron's call) from a
// box of the rig's operator workspace; its answer.
func prioSync(t *testing.T, r *fleetTokensRig, query string) map[string]any {
	t.Helper()
	return prioSyncIn(t, r.e, r.op, query)
}

// prioSyncIn runs prio-sync from a box of workspace op of e.
func prioSyncIn(t *testing.T, e *env, op, query string) map[string]any {
	t.Helper()
	ctx := context.Background()
	b := e.box(op, "box-"+newTenantID(""), "CLE-07")
	// SPL-5337: from the operator workspace the sweep walks every live
	// workspace of the shared test database; in hub group d that is every
	// one groups a..c made (1579 tenants on 2026-11-11), seconds per call on
	// a loaded box, past env.box's 5 s reply wait ("no issue reply"). A
	// test-only bound: the hub and the production client are unchanged.
	b.c.ReadyTimeout = 60 * time.Second
	e.pin(op, b)
	sa, err := b.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sa)
	raw, err := action.Issue(ctx, b.cfg, action.IssueArgs{Op: "prio-sync", As: "CLE-07", Query: query, Hub: b.c})
	if err != nil {
		t.Fatalf("prio-sync %q: %v", query, err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("reply %s: %v", raw, err)
	}
	return out
}

// ownChanges keeps the answer's changes of the rig's workspaces (on the
// shared Postgres the operator workspace's sweep also walks other tests').
func ownChanges(r *fleetTokensRig, out map[string]any) map[string]any {
	ch, _ := out["changes"].([]any)
	keep := []any{}
	for _, c := range ch {
		if m, _ := c.(map[string]any); r.ws[fmt.Sprint(m["workspace"])] {
			keep = append(keep, c)
		}
	}
	out["changes"] = keep
	return out
}

// C150-F2: the sweep applies a priority stored without the PUT (a row set
// before this rule): a dry run lists the change and writes nothing;
// dry_run=0 writes it and counts the issues with no set discussion; a
// second run changes nothing. From the operator workspace it walks every
// workspace. RED CONTROL (master 77463637a): the op does
// not exist.
func TestTopicPrioritySyncOp(t *testing.T) {
	r := newFleetTokensRig(t)
	talk := uid.New()
	lobbyTopic(t, r.e, r.op, talk, "## Sweep\n\nrow")
	k := issueWithPrio(t, r.e, r.op, r.admin, "born of talk", talk, 5)
	issueWithPrio(t, r.e, r.op, r.admin, "default only", store.IssueDiscussionDefault(r.op), 5)
	far := uid.New()
	lobbyTopic(t, r.e, r.other, far, "## Far\n\nrow")
	relayCopy(t, r.e, r.op, far)
	kFar := issueWithPrio(t, r.e, r.op, r.admin, "lane issue on a far topic", far, 5)
	ps := r.e.st.(store.TopicPriorityStore)
	if _, err := ps.SetTopicPriority(context.Background(), r.op, talk, 2, "HUM-1", time.Now()); err != nil {
		t.Fatal(err)
	}
	if _, err := ps.SetTopicPriority(context.Background(), r.other, far, 1, opOwnerSeat(t, r), time.Now()); err != nil {
		t.Fatal(err)
	}
	dry := ownChanges(r, prioSync(t, r, ""))
	if dry["applied"] != false || fmt.Sprint(dry["changes"]) != fmt.Sprintf("[map[from:5 key:%s to:2 topic:%s workspace:%s] map[from:5 key:%s to:1 topic:%s workspace:%s]]", k, talk, r.op, kFar, far, r.op) {
		t.Errorf("C150-F2 dry run: %v", dry)
	}
	if got := issuePrio(t, r.e, r.op, r.admin, k); got != 5 {
		t.Errorf("C150-F2 dry run wrote: prio %d, want 5", got)
	}
	wet := ownChanges(r, prioSync(t, r, "dry_run=0"))
	if ch, _ := wet["changes"].([]any); wet["applied"] != true || len(ch) != 2 {
		t.Errorf("C150-F2 apply: %v", wet)
	}
	if n, _ := wet["unset"].(float64); n < 1 {
		t.Errorf("C150-F2 apply: unset %v, want the default-only issue counted", wet["unset"])
	}
	if got := issuePrio(t, r.e, r.op, r.admin, k); got != 2 {
		t.Errorf("C150-F2 apply: prio %d, want 2", got)
	}
	if got := issuePrio(t, r.e, r.op, r.admin, kFar); got != 1 {
		t.Errorf("C150-F2 apply, operator issue on another workspace's topic: prio %d, want 1", got)
	}
	if ws := fmt.Sprint(wet["workspaces"]); !strings.Contains(ws, r.op) || !strings.Contains(ws, r.other) {
		t.Errorf("C150-F2 the operator workspace sweeps every workspace: %v", ws)
	}
	if ch, _ := ownChanges(r, prioSync(t, r, "dry_run=0"))["changes"].([]any); len(ch) != 0 {
		t.Errorf("C150-F2 second apply is not a no-op: %v", ch)
	}
}

// C150-F4 (R7 W1): an operator issue links a far priority 1 topic and an
// own one; the PUT on the own one gives what the sweep gives, or the issue's
// priority flips every 5 min. RED CONTROL (ca1176c0f, the PUT's operator run
// reads the operator workspace's own topics only): issue prio 3, want 1.
func TestTopicPriorityPutAgreesWithSync(t *testing.T) {
	r := newFleetTokensRig(t)
	own, far := uid.New(), uid.New()
	lobbyTopic(t, r.e, r.op, own, "## Own\n\nrow")
	lobbyTopic(t, r.e, r.other, far, "## Far\n\nrow")
	relayCopy(t, r.e, r.op, far)
	k := issueWithPrio(t, r.e, r.op, r.admin, "lane issue on two topics", own, 5)
	if code, out := call(t, r.e, r.op, http.MethodPost, "/v1/issues/"+k+"/discussions", r.admin, map[string]any{"discussion": far}); code != http.StatusOK {
		t.Fatalf("link the far topic: %d %v", code, out)
	}
	ps := r.e.st.(store.TopicPriorityStore)
	if _, err := ps.SetTopicPriority(context.Background(), r.other, far, 1, opOwnerSeat(t, r), time.Now()); err != nil {
		t.Fatal(err)
	}
	prioSync(t, r, "dry_run=0")
	if got := issuePrio(t, r.e, r.op, r.admin, k); got != 1 {
		t.Fatalf("C150-F4 sweep: issue prio %d, want 1", got)
	}
	if code, out := putPriority(t, r.e, r.op, own, r.admin, map[string]any{"priority": 3}); code != http.StatusOK {
		t.Fatalf("PUT own priority: %d %v", code, out)
	}
	if got := issuePrio(t, r.e, r.op, r.admin, k); got != 1 {
		t.Errorf("C150-F4 PUT disagrees with the sweep: issue prio %d, want 1", got)
	}
	if ch, _ := ownChanges(r, prioSync(t, r, "dry_run=0"))["changes"].([]any); len(ch) != 0 {
		t.Errorf("C150-F4 sweep after the PUT moves it again: %v", ch)
	}
}

// SPL-5933 (owner HUM-10, t1 e1139a1e, msg 41010d28: "Only t1 owners order
// the agents' work: the issue keeps the t1 owner's priority, like the queue
// does"): the operator workspace's owner (HUM-7) sets another workspace's
// topic to 1, then that workspace's own owner (HUM-8, not op's) sets it to
// 5. The topic shows 5 in its own workspace; op's queue row and op's lane
// issue linking the topic keep 1, by the PUT and by the sweep.
// RED CONTROL (parent f1048ab35): the issue takes 5, the newest set of any
// workspace (linkedSetPriorities).
func TestTopicPriorityIssueKeepsOperatorOwner(t *testing.T) {
	op := newTenantID("op")
	roles := tenantRoles{op: {"HUM-7": rbac.BizOwner}}
	e := archiveEnv(t, func(o *hub.Options) {
		o.OperatorTenant = op
		o.Authorizer = roles
	})
	pub, _, _ := ed25519.GenerateKey(nil)
	if err := e.st.CreateTenant(context.Background(), store.Tenant{ID: op, RootPubKey: pub}); err != nil {
		t.Fatal(err)
	}
	tid, _ := e.tenant()
	roles[tid] = map[string]string{"HUM-7": rbac.BizOwner, "HUM-8": rbac.BizOwner}
	task := uuidV4()
	putCard(t, e, tid, task, "", "HUM-2", hub.WUIBox, 1, time.Now().UTC().Add(-time.Hour))
	relayCopy(t, e, op, task)
	k := issueWithPrio(t, e, op, "HUM-7", "lane issue on the far topic", task, 4)
	for _, set := range []struct {
		as   string
		prio int
	}{{"HUM-7", 1}, {"HUM-8", 5}} {
		if code, out := putPriority(t, e, tid, task, set.as, map[string]any{"priority": set.prio}); code != http.StatusOK {
			t.Fatalf("%s: PUT priority %d: %d %v", set.as, set.prio, code, out)
		}
	}
	if got := storedPriority(t, e, tid, task); got != 5 {
		t.Errorf("the topic's own workspace: priority %d, want the last set 5", got)
	}
	if got := storedPriority(t, e, op, task); got != 1 {
		t.Errorf("op's queue row: priority %d, want the operator owner's 1", got)
	}
	if got := issuePrio(t, e, op, "HUM-7", k); got != 1 {
		t.Errorf("op's lane issue after the PUT: priority %d, want the operator owner's 1", got)
	}
	res := prioSyncIn(t, e, op, "dry_run=0")
	if got := issuePrio(t, e, op, "HUM-7", k); got != 1 {
		t.Errorf("op's lane issue after the sweep: priority %d, want 1 (%v)", got, res["changes"])
	}
}

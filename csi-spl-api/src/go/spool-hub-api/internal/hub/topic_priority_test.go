package hub_test

import (
	"context"
	"crypto/ed25519"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 150 v1.0 row B3 (SPL-4192): PUT /v1/topics/{task_id}/priority, the
// priority on the view rows, the topic_priority frame. Cases C305-C307 of
// the spec's section 4; each names its red control. archiveEnv: HUM-8 is the
// tenant owner, HUM-9 an admin, everyone else a developer.

func putPriority(t *testing.T, e *env, tid, task, as string, body any) (int, map[string]any) {
	t.Helper()
	return call(t, e, tid, http.MethodPut, "/v1/topics/"+task+"/priority", as, body)
}

// listedPriority is task's priority on HUM-x's topic list; ok false = the
// row is not listed or carries no priority.
func listedPriority(t *testing.T, e *env, tid, as, task string) (float64, bool) {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/view/topics?roots=false", as, nil)
	if code != http.StatusOK {
		t.Fatalf("topics: %d %v", code, out)
	}
	rows, _ := out["topics"].([]any)
	for _, raw := range rows {
		row, _ := raw.(map[string]any)
		if row["task_id"] == task {
			p, ok := row["priority"].(float64)
			return p, ok
		}
	}
	return 0, false
}

// unsetTopicPriority is what a topic nobody set reads: 3, the owner's
// default (msg f5ed1396, spec 150 v1.1 D7, SPL-4367), a literal so the
// tests hold the owner's value, not the constant's.
const unsetTopicPriority = 3

func storedPriority(t *testing.T, e *env, tid, task string) int {
	t.Helper()
	got, err := e.st.(store.TopicPriorityStore).TopicPriorities(context.Background(), tid, []string{task})
	if err != nil {
		t.Fatal(err)
	}
	return got[task]
}

// C305 read door: a reader who cannot read the topic gets 404 on PUT, and
// nothing is stored. Red control: skip the canReadTopic check in
// priorityDoor -> the DM outsider gets 200 and the row reads 1.
func TestTopicPriorityReadDoor(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	dm := uuidV4()
	id := uuidV4()
	now := time.Now().UTC()
	m := store.Message{TenantID: tid, MsgID: id, TaskID: dm, IsParent: 1, TS: now, FromBox: hub.WUIBox, FromID: "HUM-1",
		ToBox: "box-b", ToID: "CLE-07", Kind: "note", Body: "a DM " + id, Files: []byte(`[]`), Msg: []byte(`{"v":1}`),
		Env: []byte(`{"id":"` + id + `"}`), ReceivedAt: now, ExpiresAt: now.Add(30 * 24 * time.Hour)}
	if _, err := e.st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
	for _, as := range []string{"HUM-2", "HUM-9"} { // a member, an admin: neither is an end of the DM
		if code, out := putPriority(t, e, tid, dm, as, map[string]any{"priority": 1}); code != http.StatusNotFound || out["error"] != "not_found" {
			t.Fatalf("%s outside the DM: %d %v", as, code, out)
		}
	}
	if got := storedPriority(t, e, tid, dm); got != unsetTopicPriority {
		t.Fatalf("a refused PUT stored %d", got)
	}
	// An unknown topic and a task id that is no uuid read the same.
	for _, task := range []string{uuidV4(), "not-a-uuid"} {
		if code, _ := putPriority(t, e, tid, task, "HUM-1", map[string]any{"priority": 1}); code != http.StatusNotFound {
			t.Fatalf("PUT %s: %d", task, code)
		}
	}
	// The DM's end may.
	if code, out := putPriority(t, e, tid, dm, "HUM-1", map[string]any{"priority": 2}); code != http.StatusOK || out["priority"] != float64(2) {
		t.Fatalf("the DM's end: %d %v", code, out)
	}
}

// C306 policy: with "Who can archive topics" = admins, a member gets 403
// not_allowed; an admin and the owner may. Red control: skip
// mayArchiveByPolicy in priorityAllowed -> the member gets 200.
func TestTopicPriorityPolicy(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	admins := store.ArchivePolicyAdmins
	if err := e.st.(store.TenantSettings).SetTenantConfig(context.Background(), tid, store.TenantConfigPatch{TopicArchivePolicy: &admins}); err != nil {
		t.Fatal(err)
	}
	T := uuidV4()
	putCard(t, e, tid, T, "", "HUM-1", hub.WUIBox, 1, time.Now().UTC())
	for _, as := range []string{"HUM-1", "HUM-2"} { // the starter and another member
		if code, out := putPriority(t, e, tid, T, as, map[string]any{"priority": 1}); code != http.StatusForbidden || out["error"] != "not_allowed" {
			t.Fatalf("%s under admins: %d %v", as, code, out)
		}
	}
	if got := storedPriority(t, e, tid, T); got != unsetTopicPriority {
		t.Fatalf("a refused PUT stored %d", got)
	}
	// No member session (an agent, a box): refused before the door.
	if code, out := putPriority(t, e, tid, T, "", map[string]any{"priority": 1}); code != http.StatusForbidden {
		t.Fatalf("no session: %d %v", code, out)
	}
	for i, as := range []string{"HUM-9", "HUM-8"} {
		prio := float64(2 + i)
		code, out := putPriority(t, e, tid, T, as, map[string]any{"priority": prio})
		if code != http.StatusOK || out["priority"] != prio || out["set_by"] != as || out["task_id"] != T || out["set_at"] == "" {
			t.Fatalf("%s under admins: %d %v", as, code, out)
		}
	}
	// The default policy (everyone) lets the member through.
	everyone := store.ArchivePolicyEveryone
	if err := e.st.(store.TenantSettings).SetTenantConfig(context.Background(), tid, store.TenantConfigPatch{TopicArchivePolicy: &everyone}); err != nil {
		t.Fatal(err)
	}
	if code, out := putPriority(t, e, tid, T, "HUM-2", map[string]any{"priority": 4}); code != http.StatusOK {
		t.Fatalf("member under everyone: %d %v", code, out)
	}
}

// C307 list rows carry it: a GET /v1/view/topics row has priority, 3 when
// nobody set it (the owner's default, msg f5ed1396, SPL-4367), the set value after a PUT; the topic read carries it too.
// Red control: drop the attachTopicPriorities call in listTopics -> the
// row has no priority.
func TestTopicPriorityOnViewRows(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	now := time.Now().UTC()
	T, U := uuidV4(), uuidV4()
	putCard(t, e, tid, T, "", "HUM-1", hub.WUIBox, 1, now)
	putCard(t, e, tid, U, "", "HUM-1", hub.WUIBox, 1, now.Add(time.Second))
	if p, ok := listedPriority(t, e, tid, "HUM-2", T); !ok || p != unsetTopicPriority {
		t.Fatalf("unset row: %v %v", p, ok)
	}
	if code, out := putPriority(t, e, tid, T, "HUM-2", map[string]any{"priority": 4}); code != http.StatusOK {
		t.Fatalf("set: %d %v", code, out)
	}
	if p, ok := listedPriority(t, e, tid, "HUM-2", T); !ok || p != 4 {
		t.Fatalf("set row: %v %v", p, ok)
	}
	if p, ok := listedPriority(t, e, tid, "HUM-2", U); !ok || p != unsetTopicPriority {
		t.Fatalf("the other row: %v %v", p, ok)
	}
	if code, out := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+T, "HUM-2", nil); code != http.StatusOK || out["priority"] != float64(4) {
		t.Fatalf("topic read: %d %v", code, out["priority"])
	}
	if code, out := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+U, "HUM-2", nil); code != http.StatusOK || out["priority"] != float64(unsetTopicPriority) {
		t.Fatalf("unset topic read: %d %v", code, out["priority"])
	}
}

// Bounds: 0, 6, a missing and a non-number priority are 400 bad_json, and
// nothing is stored; 1 and 5 are accepted.
func TestTopicPriorityBounds(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	T := uuidV4()
	putCard(t, e, tid, T, "", "HUM-1", hub.WUIBox, 1, time.Now().UTC())
	for _, body := range []any{map[string]any{"priority": 0}, map[string]any{"priority": 6},
		map[string]any{}, map[string]any{"priority": "1"}, map[string]any{"priority": 2.5}} {
		if code, out := putPriority(t, e, tid, T, "HUM-1", body); code != http.StatusBadRequest || out["error"] != "bad_json" {
			t.Fatalf("%v: %d %v", body, code, out)
		}
	}
	if got := storedPriority(t, e, tid, T); got != unsetTopicPriority {
		t.Fatalf("a refused PUT stored %d", got)
	}
	for _, p := range []int{1, 5} {
		if code, out := putPriority(t, e, tid, T, "HUM-1", map[string]any{"priority": p}); code != http.StatusOK || out["priority"] != float64(p) {
			t.Fatalf("%d: %d %v", p, code, out)
		}
	}
}

// The live frame: a second open view of the topic gets topic_priority with
// the new value, without a refetch.
func TestTopicPriorityFrame(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	T := uuidV4()
	putCard(t, e, tid, T, "", "HUM-1", hub.WUIBox, 1, time.Now().UTC())
	watcher := dialMember(t, e, tid, "HUM-2", "HUM-2")
	wsjson.Write(context.Background(), watcher, map[string]string{"type": "subscribe", "task_id": T}) //nolint:errcheck
	readType(t, watcher, "subscribed")
	if code, out := putPriority(t, e, tid, T, "HUM-1", map[string]any{"priority": 2}); code != http.StatusOK {
		t.Fatalf("set: %d %v", code, out)
	}
	if f := readType(t, watcher, "topic_priority"); f["task_id"] != T || f["priority"] != float64(2) || f["set_by"] != "HUM-1" || f["channel"] != "lobby" {
		t.Fatalf("frame: %v", f)
	}
	watcher.Close(websocket.StatusNormalClosure, "") //nolint:errcheck
}

// The operator copy and its queue (moved from owner_prio_word_test.go when
// the owner's prio word was retired, spec 150 B14, SPL-6622).

// prioQueue is a topic with an opening card, a queued feature ask working
// for it, and an older queued bug with no discussion that ranks before it.
type prioQueue struct {
	e        *env
	tid      string
	task     string
	askTopic string
	askOther string
}

func newPrioQueue(t *testing.T) prioQueue {
	t.Helper()
	e := archiveEnv(t)
	tid, _ := e.tenant()
	t0 := time.Now().UTC().Add(-time.Hour)
	q := prioQueue{e: e, tid: tid, task: uuidV4(), askTopic: uuidV4(), askOther: uuidV4()}
	putCard(t, e, tid, q.task, "", "HUM-2", hub.WUIBox, 1, t0)
	queuePrioAsks(t, e, tid, q)
	return q
}

// queuePrioAsks queues, in tid, an older bug with no discussion and a
// feature ask working for q.task, which therefore ranks 2nd.
func queuePrioAsks(t *testing.T, e *env, tid string, q prioQueue) {
	t.Helper()
	ctx := context.Background()
	t0 := time.Now().UTC().Add(-time.Hour)
	for i, a := range []struct{ id, disc, class string }{{q.askOther, "", "bug"}, {q.askTopic, q.task, "feature"}} {
		at := t0.Add(time.Duration(i) * time.Minute)
		if _, _, err := e.st.PutFleetAsk(ctx, tid, store.FleetAsk{Fleet: "main", AskID: a.id, Role: "orch", Kind: "task",
			From: "c-002@box-b", Topic: "dispatch-" + q.task[:8], Discussion: a.disc, Summary: "SPAWN REQUEST " + a.class}, "box-b", at); err != nil {
			t.Fatal(err)
		}
		if _, err := e.st.UpdateFleetAsk(ctx, tid, store.AskUpdate{Fleet: "main", AskID: a.id, Op: store.AskQueue, By: "c-001@sat", Class: a.class}, "sat", at); err != nil {
			t.Fatal(err)
		}
	}
	q.tid = tid
	if got := q.position(t); got != 2 {
		t.Fatalf("before any post the topic's ask is at %d in %s, want 2", got, tid)
	}
}

// position is the topic's ask's place in the orch queue.
func (q prioQueue) position(t *testing.T) int {
	t.Helper()
	as, err := q.e.st.ListFleetAsks(context.Background(), q.tid, "main", "orch", false, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	for _, a := range as {
		if a.AskID == q.askTopic {
			return a.Position
		}
	}
	t.Fatalf("ask %s is not listed", q.askTopic)
	return 0
}

// tenantRoles is an authorizer whose roles depend on the workspace; any
// other member is a developer.
type tenantRoles map[string]map[string]string

func (m tenantRoles) Access(ctx context.Context, hum, tenant string) (rbac.Access, error) {
	if r, ok := m[tenant][hum]; ok {
		return rbac.Fixed(r).Access(ctx, hum, tenant)
	}
	return rbac.Fixed(rbac.Developer).Access(ctx, hum, tenant)
}

func (m tenantRoles) Roles(ctx context.Context, tenant string) (map[string]rbac.Role, error) {
	return rbac.Fixed(rbac.Developer).Roles(ctx, tenant)
}

// SPL-5905 (prd ask 58a67da0): the priority chooser, PUT
// /v1/topics/{task_id}/priority, on a topic of another workspace copies the
// set into the operator workspace (priorityOperatorTenant). The operator
// workspace's owner (HUM-7, also an owner of the topic's workspace) setting
// 1 moves op's ask working for the topic to the head; the topic workspace's
// own owner (HUM-8, not op's) sets the topic there and op's queue keeps its
// order and its own unset row.
// RED CONTROL: drop the priorityToOperator call in handleTopicPriority ->
// the HUM-7 case fails with op's ask at 2 and op's row at 3.
func TestTopicPriorityOperatorQueue(t *testing.T) {
	for _, c := range []struct {
		name, as      string
		want, wantRow int
	}{
		{"the operator workspace's owner", "HUM-7", 1, 1},
		{"the topic workspace's owner only", "HUM-8", 2, unsetTopicPriority},
	} {
		t.Run(c.name, func(t *testing.T) {
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
			q := prioQueue{e: e, tid: op, task: uuidV4(), askTopic: uuidV4(), askOther: uuidV4()}
			queuePrioAsks(t, e, op, q)
			putCard(t, e, tid, q.task, "", "HUM-2", hub.WUIBox, 1, time.Now().UTC().Add(-time.Hour))
			if code, out := putPriority(t, e, tid, q.task, c.as, map[string]any{"priority": 1}); code != http.StatusOK {
				t.Fatalf("%s: PUT priority %d %v", c.as, code, out)
			}
			if got := storedPriority(t, e, tid, q.task); got != 1 {
				t.Fatalf("%s: the topic's own priority %d, want 1", c.as, got)
			}
			if got := storedPriority(t, e, op, q.task); got != c.wantRow {
				t.Fatalf("%s: op's row for the topic %d, want %d", c.as, got, c.wantRow)
			}
			if got := q.position(t); got != c.want {
				t.Fatalf("%s: op's ask is at %d, want %d", c.as, got, c.want)
			}
		})
	}
}

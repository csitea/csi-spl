package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
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
	if got := storedPriority(t, e, tid, dm); got != store.TopicPriorityDefault {
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
	if got := storedPriority(t, e, tid, T); got != store.TopicPriorityDefault {
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

// C307 list rows carry it: a GET /v1/view/topics row has priority, 5 when
// nobody set it, the set value after a PUT; the topic read carries it too.
// Red control: drop the attachTopicPriorities call in listTopics -> the
// row has no priority.
func TestTopicPriorityOnViewRows(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	now := time.Now().UTC()
	T, U := uuidV4(), uuidV4()
	putCard(t, e, tid, T, "", "HUM-1", hub.WUIBox, 1, now)
	putCard(t, e, tid, U, "", "HUM-1", hub.WUIBox, 1, now.Add(time.Second))
	if p, ok := listedPriority(t, e, tid, "HUM-2", T); !ok || p != store.TopicPriorityDefault {
		t.Fatalf("unset row: %v %v", p, ok)
	}
	if code, out := putPriority(t, e, tid, T, "HUM-2", map[string]any{"priority": 3}); code != http.StatusOK {
		t.Fatalf("set: %d %v", code, out)
	}
	if p, ok := listedPriority(t, e, tid, "HUM-2", T); !ok || p != 3 {
		t.Fatalf("set row: %v %v", p, ok)
	}
	if p, ok := listedPriority(t, e, tid, "HUM-2", U); !ok || p != store.TopicPriorityDefault {
		t.Fatalf("the other row: %v %v", p, ok)
	}
	if code, out := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+T, "HUM-2", nil); code != http.StatusOK || out["priority"] != float64(3) {
		t.Fatalf("topic read: %d %v", code, out["priority"])
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
	if got := storedPriority(t, e, tid, T); got != store.TopicPriorityDefault {
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

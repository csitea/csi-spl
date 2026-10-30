package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"os"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 166 v0.3 row B5 (SPL-4323): GET /v1/operator/zombie-topics, the idle
// topic heads of the operator workspace (3.2 conditions 1, 2 and 6). Postgres
// under SPOOL_TEST_PG_DSN (PRE_PUSH_TIER=full); the memory store keeps no
// heads and answers 501. RED CONTROL (the tree before the row): the route
// does not exist, GET answers 404.

const zombiePath = "/v1/operator/zombie-topics"

// zombiePut stores one line of task at, the topic's card (msg_id = task id)
// when card is set: channel "" is a DM line between two agents.
func zombiePut(t *testing.T, r *fleetTokensRig, task, channel string, card bool, at time.Time) {
	t.Helper()
	id := uuidV4()
	if card {
		id = task
	}
	from, to := "HUM-2", "ALL-0"
	if channel == "" {
		from, to = "CLE-07", "CLE-08"
	}
	inner := `{"v":1,"msg_id":"` + id + `","task_id":"` + task + `","from":"` + from + `","to":"` + to +
		`","kind":"note","body":"zombie","files":[]}`
	m := store.Message{TenantID: r.op, MsgID: id, TaskID: task, Channel: channel, TS: at,
		FromBox: "box-wui", FromID: from, ToBox: "box-wui", ToID: to, Kind: "note", Body: "zombie",
		Files: []byte("[]"), Msg: []byte(inner), Env: []byte(`{"msg":` + inner + `,"sig":""}`),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
	if _, err := r.e.st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
}

type zombieList struct {
	IdleDays int `json:"idle_days"`
	Limit    int `json:"limit"`
	Topics   []struct {
		TaskID string `json:"task_id"`
		LastAt string `json:"last_at"`
	} `json:"topics"`
}

// getZombies is GET path as the operator admin, its status and its ids.
func getZombies(t *testing.T, r *fleetTokensRig, path string) (int, zombieList, []string) {
	t.Helper()
	code, body := call(t, r.e, r.op, http.MethodGet, path, r.admin, nil)
	raw, _ := json.Marshal(body)
	var v zombieList
	json.Unmarshal(raw, &v) //nolint:errcheck
	ids := []string{}
	for _, z := range v.Topics {
		ids = append(ids, z.TaskID)
	}
	return code, v, ids
}

// TestZombieTopicsMemoryUnsupported: the route exists on every hub (the red
// control's 404 is gone); the memory store answers 501, never an empty list.
func TestZombieTopicsMemoryUnsupported(t *testing.T) {
	if os.Getenv("SPOOL_TEST_PG_DSN") != "" {
		t.Skip("memory store only")
	}
	r := newFleetTokensRig(t)
	if code, _, _ := getZombies(t, r, zombiePath); code != http.StatusNotImplemented {
		t.Fatalf("GET %s on the memory store: %d, want 501 (404 = the route is missing)", zombiePath, code)
	}
}

// TestZombieTopicsListsIdleHeads: row B5's cases on Postgres.
func TestZombieTopicsListsIdleHeads(t *testing.T) {
	if os.Getenv("SPOOL_TEST_PG_DSN") == "" {
		t.Skip("topic heads need Postgres (SPOOL_TEST_PG_DSN)")
	}
	r := newFleetTokensRig(t)
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	days := func(d int) time.Time { return now.Add(-time.Duration(d) * 24 * time.Hour) }
	idle, archived, dm, prio, young := uuidV4(), uuidV4(), uuidV4(), uuidV4(), uuidV4()
	zombiePut(t, r, idle, store.ChannelLobby, true, days(8))
	zombiePut(t, r, archived, store.ChannelLobby, true, days(8))
	zombiePut(t, r, dm, "", true, days(8))
	zombiePut(t, r, prio, store.ChannelLobby, true, days(8))
	zombiePut(t, r, young, store.ChannelLobby, true, days(6))
	if _, err := r.e.st.SetArchived(ctx, r.op, archived, "HUM-2", days(8), true); err != nil {
		t.Fatal(err)
	}
	if _, err := r.e.st.(store.TopicPriorityStore).SetTopicPriority(ctx, r.op, prio, 3, "HUM-2", days(8)); err != nil {
		t.Fatal(err)
	}

	code, v, ids := getZombies(t, r, zombiePath+"?idle_days=7")
	if code != http.StatusOK {
		t.Fatalf("GET %s?idle_days=7: %d (404 = the route is missing)", zombiePath, code)
	}
	if !slices.Equal(ids, []string{idle}) {
		t.Fatalf("idle_days=7 listed %v, want only the idle topic %s (archived %s, dm %s, prioritised %s, idle 6 days %s)",
			ids, idle, archived, dm, prio, young)
	}
	if v.IdleDays != 7 || v.Limit != 500 {
		t.Fatalf("answer idle_days %d limit %d, want 7 and the default 500", v.IdleDays, v.Limit)
	}
	if _, _, ids = getZombies(t, r, zombiePath); !slices.Equal(ids, []string{idle}) {
		t.Fatalf("default idle_days listed %v, want [%s]", ids, idle)
	}
	// idle_days=5: the 6-day topic joins, oldest first; limit=1 keeps the oldest.
	if _, _, ids = getZombies(t, r, zombiePath+"?idle_days=5"); !slices.Equal(ids, []string{idle, young}) {
		t.Fatalf("idle_days=5 listed %v, want [%s %s]", ids, idle, young)
	}
	if _, _, ids = getZombies(t, r, zombiePath+"?idle_days=5&limit=1"); !slices.Equal(ids, []string{idle}) {
		t.Fatalf("idle_days=5&limit=1 listed %v, want [%s]", ids, idle)
	}
	// Read only: the listed topic is still unarchived after every read.
	if _, _, ids = getZombies(t, r, zombiePath); !slices.Equal(ids, []string{idle}) {
		t.Fatalf("a second read listed %v: a read changed a head", ids)
	}
}

// TestZombieTopicsRefusals: bad numbers; the operator developer, an admin of
// another workspace and an anonymous caller (R7 W1).
func TestZombieTopicsRefusals(t *testing.T) {
	r := newFleetTokensRig(t)
	for _, q := range []string{"?idle_days=0", "?idle_days=x", "?idle_days=3651", "?limit=0", "?limit=5001", "?limit=-1"} {
		if code, _, _ := getZombies(t, r, zombiePath+q); code != http.StatusBadRequest {
			t.Errorf("GET %s%s: %d, want 400", zombiePath, q, code)
		}
	}
	for name, who := range map[string][2]string{"operator developer": {r.op, r.dev}, "other workspace admin": {r.other, r.otherA}, "anonymous": {r.op, ""}} {
		if code, body := call(t, r.e, who[0], http.MethodGet, zombiePath, who[1], nil); code != http.StatusForbidden || body["permission"] != "operator.workspaces" {
			t.Errorf("GET %s as %s: %d %v, want 403 operator.workspaces", zombiePath, name, code, body)
		}
	}
}

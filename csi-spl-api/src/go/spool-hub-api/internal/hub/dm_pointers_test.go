package hub_test

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
)

// Owner, prd t1 dc6d5e3f (HUM-10): "if I tag the agent in a channels topic,
// it means that this msg WILL appear also as a personal msg ... but of course
// it should be treated as a reply in the topic and not a new topic". The DM
// view of the person and the agent (?dm=true&peer=<agent>) carries the
// channel lines between them as `pointers`: the tag and the agent's answer,
// each the stored row with its channel and task_id - no copy, no new topic.
// CONTROL: before dm_pointers.go the DM view held neither line (its walk
// requires channel IS NULL), n=1. Memory store; with SPOOL_TEST_PG_DSN the
// store read runs on Postgres (store TestViewDMPointers).
func TestViewTopicsDMPointers(t *testing.T) {
	r := newDoorRig(t)
	tenant, _ := r.e.tenant()
	if landed := r.signIn(t, tenant); strings.Contains(landed, "auth_error") {
		t.Fatalf("sign-in landed on %s", landed)
	}
	ctx := context.Background()
	c, _, err := websocket.Dial(ctx, "ws://"+tenant+domain+"/v1/wui/ws", &websocket.DialOptions{HTTPClient: r.browser})
	if err != nil {
		t.Fatal(err)
	}
	defer c.CloseNow()                                       //nolint:errcheck
	wsjson.Write(ctx, c, map[string]string{"type": "hello"}) //nolint:errcheck
	w := &wuiClient{t: t, c: c}
	me := w.read("welcome").As

	bx := r.e.box(tenant, "box-a", "CLE-07", "CLE-08")
	r.e.pin(tenant, bx)
	post := func(f map[string]any) string {
		f["type"] = "send"
		wsjson.Write(ctx, c, f) //nolint:errcheck
		ack := w.read("ack")
		time.Sleep(2 * time.Millisecond) // distinct received_at
		return ack.MsgID
	}
	topic := uuid4()
	post(map[string]any{"channel": "lobby", "task_id": topic, "body": "a lobby topic", "is_parent": 1})
	tag := post(map[string]any{"task_id": topic, "to": "CLE-07", "to_box": "box-a", "body": "@CLE-07 look at this", "is_parent": 0})
	post(map[string]any{"task_id": topic, "body": "a reply that tags nobody", "is_parent": 0})
	dmTask := uuid4()
	post(map[string]any{"task_id": dmTask, "to": "CLE-07", "to_box": "box-a", "body": "a plain DM"})
	ans, err := action.SendCtx(ctx, bx.cfg, action.SendArgs{From: "CLE-07", To: me, TaskID: topic, Kind: "note",
		Body: "The build fails in step 3: the cache key misses the lockfile hash.", ToBox: "box-wui", Hub: bx.c})
	if err != nil {
		t.Fatal(err)
	}
	time.Sleep(200 * time.Millisecond)

	type row struct {
		Channel string `json:"channel"`
		Env     struct {
			Msg struct {
				MsgID  string `json:"msg_id"`
				TaskID string `json:"task_id"`
			} `json:"msg"`
		} `json:"env"`
	}
	read := func(peer string) ([]string, []string, []row) {
		t.Helper()
		code, _, body := r.get(t, tenant, "/v1/view/topics?dm=true&limit=50&per_topic=5&peer="+peer)
		if code != http.StatusOK {
			t.Fatalf("peer %s: %d %s", peer, code, body)
		}
		var list struct {
			Topics []struct {
				TaskID string `json:"task_id"`
			} `json:"topics"`
			Pointers []row `json:"pointers"`
		}
		if err := json.Unmarshal([]byte(body), &list); err != nil {
			t.Fatal(err)
		}
		var tasks, ptrs []string
		for _, tp := range list.Topics {
			tasks = append(tasks, tp.TaskID)
		}
		for _, p := range list.Pointers {
			ptrs = append(ptrs, p.Env.Msg.MsgID)
		}
		return tasks, ptrs, list.Pointers
	}
	tasks, ptrs, rows := read("CLE-07")
	if want := []string{ans.MsgID, tag}; !reflect.DeepEqual(ptrs, want) {
		t.Fatalf("pointers %v, want [answer tag] %v", ptrs, want)
	}
	for _, p := range rows {
		if p.Channel != "lobby" || p.Env.Msg.TaskID != topic {
			t.Fatalf("pointer %s: channel %q task %q, want lobby in %s (a reply in its topic)", p.Env.Msg.MsgID, p.Channel, p.Env.Msg.TaskID, topic)
		}
	}
	if !reflect.DeepEqual(tasks, []string{dmTask}) {
		t.Fatalf("DM topics %v, want only the plain DM %s (the channel topic is no DM topic)", tasks, dmTask)
	}
	if _, ptrs, _ := read("CLE-07@box-a"); len(ptrs) != 2 {
		t.Fatalf("peer CLE-07@box-a: pointers %v, want 2", ptrs)
	}
	if _, ptrs, _ := read("CLE-08"); len(ptrs) != 0 {
		t.Fatalf("peer CLE-08 (never tagged): pointers %v", ptrs)
	}
	// an older page carries none: the pointers ride the first page only
	before := base64.RawURLEncoding.EncodeToString([]byte("2099-01-01T00:00:00Z|" + dmTask))
	if code, _, body := r.get(t, tenant, "/v1/view/topics?dm=true&limit=1&peer=CLE-07&before="+before); code != http.StatusOK || strings.Contains(body, `"pointers"`) {
		t.Fatalf("before= page: %d %s", code, body)
	}
}

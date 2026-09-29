package hub_test

import (
	"context"
	"errors"
	"net/http"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-983 (specs/041 contracts/topic-archive-v1.md). The owner's rule: the
// card's author, the tenant owner and an admin may archive or delete; nobody
// else, and never an agent. Every refusal is a control: remove its guard in
// topic_archive.go and the test goes red.

// archiveEnv: HUM-8 is the tenant owner, HUM-9 an admin, everyone else a
// developer (roleOf, message_kind_test.go).
func archiveEnv(t *testing.T) *env {
	return newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.Authorizer = roleOf{"HUM-8": rbac.BizOwner, "HUM-9": rbac.Admin}
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
	})
}

// putCard stores a row the way the hub stores a browser (box-wui) or box
// line, in the public lobby channel so the read door lets every member in.
func putCard(t *testing.T, e *env, tid, task, parent, fromID, fromBox string, isParent int, at time.Time) string {
	t.Helper()
	id := uuidV4()
	m := store.Message{TenantID: tid, MsgID: id, TaskID: task, ParentTaskID: parent, Channel: "lobby", IsParent: isParent,
		TS: at, FromBox: fromBox, FromID: fromID, ToBox: "box-b", ToID: "CLE-07", Kind: "note", Body: "hello " + id,
		Files: []byte(`[]`), Msg: []byte(`{"v":1}`), Env: []byte(`{"id":"` + id + `"}`),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}
	if _, err := e.st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
	return id
}

func has(t *testing.T, e *env, tid, id string) bool {
	t.Helper()
	ok, err := e.st.HasMessage(context.Background(), tid, id)
	if err != nil {
		t.Fatal(err)
	}
	return ok
}

func listedTasks(t *testing.T, e *env, tid, as string) map[string]bool {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/view/topics?roots=false", as, nil)
	if code != http.StatusOK {
		t.Fatalf("topics: %d %v", code, out)
	}
	got := map[string]bool{}
	rows, _ := out["topics"].([]any)
	for _, raw := range rows {
		row, _ := raw.(map[string]any)
		id, _ := row["task_id"].(string)
		got[id] = true
	}
	return got
}

func TestTopicArchivePermissions(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	now := time.Now().UTC()
	T, G := uuidV4(), uuidV4()
	card := putCard(t, e, tid, T, "", "HUM-1", hub.WUIBox, 1, now)
	reply := putCard(t, e, tid, T, "", "HUM-2", hub.WUIBox, 0, now.Add(time.Second))
	agentCard := putCard(t, e, tid, G, "", "CLE-07", "box-a", 1, now.Add(2*time.Second))

	// No member session: an agent, a box, a door-off guest. Refused, nothing changed.
	for _, path := range []string{"/archive", "/topic"} {
		method := http.MethodPut
		if path == "/topic" {
			method = http.MethodDelete
		}
		if code, out := call(t, e, tid, method, "/v1/messages/"+card+path, "", nil); code != http.StatusForbidden {
			t.Fatalf("no session %s %s: %d %v", method, path, code, out)
		}
	}
	// An ordinary member is neither the author, the owner nor an admin.
	if code, out := call(t, e, tid, http.MethodPut, "/v1/messages/"+card+"/archive", "HUM-2", nil); code != http.StatusForbidden || out["error"] != "not_allowed" {
		t.Fatalf("member archive: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/messages/"+card+"/topic", "HUM-2", nil); code != http.StatusForbidden || out["error"] != "not_allowed" {
		t.Fatalf("member delete: %d %v", code, out)
	}
	// An agent's card: a member who did not write it is refused too.
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/messages/"+agentCard+"/topic", "HUM-1", nil); code != http.StatusForbidden {
		t.Fatalf("member deletes an agent's topic: %d %v", code, out)
	}
	if !has(t, e, tid, card) || !has(t, e, tid, reply) || !has(t, e, tid, agentCard) {
		t.Fatal("a refusal deleted something")
	}
	if st, _ := e.st.CardState(context.Background(), tid, card, now); !st.ArchivedAt.IsZero() {
		t.Fatal("a refusal archived the card")
	}
	// A reply is not a card.
	if code, out := call(t, e, tid, http.MethodPut, "/v1/messages/"+reply+"/archive", "HUM-2", nil); code != http.StatusConflict || out["error"] != "not_a_card" {
		t.Fatalf("archive a reply: %d %v", code, out)
	}
	// Unknown / another tenant's: 404.
	other, _ := e.tenant()
	if code, _ := call(t, e, other, http.MethodPut, "/v1/messages/"+card+"/archive", "HUM-1", nil); code != http.StatusNotFound {
		t.Fatalf("another tenant's card: %d", code)
	}

	// The author archives: T leaves the list, the Archive view has it.
	code, out := call(t, e, tid, http.MethodPut, "/v1/messages/"+card+"/archive", "HUM-1", nil)
	if code != http.StatusOK || out["archived"] != true || out["archived_by"] != "HUM-1" {
		t.Fatalf("author archive: %d %v", code, out)
	}
	if got := listedTasks(t, e, tid, "HUM-2"); got[T] || !got[G] {
		t.Fatalf("after archive: %v", got)
	}
	code, out = call(t, e, tid, http.MethodGet, "/v1/view/archived", "HUM-2", nil)
	cards, _ := out["cards"].([]any)
	if code != http.StatusOK || len(cards) != 1 {
		t.Fatalf("archived view: %d %v", code, out)
	}
	c0, _ := cards[0].(map[string]any)
	if c0["msg_id"] != card || c0["replies"] != float64(1) || c0["can_delete"] != false {
		t.Fatalf("archived card for a member: %v", c0)
	}
	if _, out := call(t, e, tid, http.MethodGet, "/v1/view/archived", "HUM-1", nil); out["cards"].([]any)[0].(map[string]any)["can_delete"] != true {
		t.Fatalf("archived card for the author: %v", out)
	}
	// The topic is still readable by its id.
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+T, "HUM-2", nil); code != http.StatusOK {
		t.Fatalf("archived topic read: %d", code)
	}

	// The tenant owner unarchives; an admin archives the agent's topic.
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/messages/"+card+"/archive", "HUM-8", nil); code != http.StatusOK || out["archived"] != false {
		t.Fatalf("owner unarchive: %d %v", code, out)
	}
	if got := listedTasks(t, e, tid, "HUM-2"); !got[T] {
		t.Fatalf("after unarchive: %v", got)
	}
	if code, out := call(t, e, tid, http.MethodPut, "/v1/messages/"+agentCard+"/archive", "HUM-9", nil); code != http.StatusOK {
		t.Fatalf("admin archives an agent's topic: %d %v", code, out)
	}

	// The confirm dialog's count, then the owner deletes card + reply.
	code, out = call(t, e, tid, http.MethodGet, "/v1/view/messages/"+card+"/topic", "HUM-8", nil)
	if code != http.StatusOK || out["replies"] != float64(1) || out["can_delete"] != true {
		t.Fatalf("topic size: %d %v", code, out)
	}
	code, out = call(t, e, tid, http.MethodDelete, "/v1/messages/"+card+"/topic", "HUM-8", nil)
	if code != http.StatusOK || out["deleted"] != float64(2) {
		t.Fatalf("owner delete: %d %v", code, out)
	}
	if has(t, e, tid, card) || has(t, e, tid, reply) || !has(t, e, tid, agentCard) {
		t.Fatal("delete removed the wrong rows")
	}
	// An admin deletes the agent's topic; the author deletes their own.
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/messages/"+agentCard+"/topic", "HUM-9", nil); code != http.StatusOK {
		t.Fatalf("admin delete: %d %v", code, out)
	}
	own := putCard(t, e, tid, uuidV4(), "", "HUM-1", hub.WUIBox, 1, now.Add(3*time.Second))
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/messages/"+own+"/topic", "HUM-1", nil); code != http.StatusOK || has(t, e, tid, own) {
		t.Fatalf("author delete: %d %v", code, out)
	}
}

// A topic whose OLDEST row is a reply (is_parent=0) - a channel message, a
// moved-in message or a desk DM stored before the opening card - is still
// archivable and deletable through its card. The card is the earliest
// is_parent=1 row, not the earliest row of any level (prd t1 topic e802196b,
// 2026-09-29). The control: before the fix the card fails resolveCard's
// "opening card" test and both routes answer 409 not_a_card.
func TestTopicArchiveOldestRowReply(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	now := time.Now().UTC()
	T := uuidV4()
	putCard(t, e, tid, T, "", "HUM-2", hub.WUIBox, 0, now)                          // the oldest row is a reply
	card := putCard(t, e, tid, T, "", "HUM-1", hub.WUIBox, 1, now.Add(time.Second)) // the opening card, stored after it

	// The confirm dialog offers the card, then the owner archives it: T
	// leaves the list. Both would 409 not_a_card before the fix.
	if code, out := call(t, e, tid, http.MethodGet, "/v1/view/messages/"+card+"/topic", "HUM-8", nil); code != http.StatusOK || out["can_archive"] != true {
		t.Fatalf("topic size: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodPut, "/v1/messages/"+card+"/archive", "HUM-8", nil); code != http.StatusOK || out["archived"] != true {
		t.Fatalf("owner archive of an oldest-reply topic: %d %v", code, out)
	}
	if got := listedTasks(t, e, tid, "HUM-2"); got[T] {
		t.Fatalf("archived topic still listed: %v", got)
	}
	if code, _ := call(t, e, tid, http.MethodDelete, "/v1/messages/"+card+"/archive", "HUM-8", nil); code != http.StatusOK {
		t.Fatalf("owner unarchive: %d", code)
	}
	// Delete removes the card and the reply that predated it.
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/messages/"+card+"/topic", "HUM-8", nil); code != http.StatusOK || out["deleted"] != float64(2) {
		t.Fatalf("owner delete of an oldest-reply topic: %d %v", code, out)
	}
}

// A lobby card: archive hides it from the lobby feed and tells the open
// sockets; delete takes it and its thread, never another lobby card.
func TestTopicArchiveLobbyFrames(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	author := dialMember(t, e, tid, "HUM-1", "HUM-1")
	watcher := dialMember(t, e, tid, "HUM-2", "HUM-2")
	for _, c := range []*websocket.Conn{author, watcher} {
		wsjson.Write(context.Background(), c, map[string]string{"type": "subscribe", "task_id": lobby}) //nolint:errcheck
		readType(t, c, "subscribed")
	}
	id, _ := postNote(t, author, "archive me")["msg_id"].(string)
	readType(t, watcher, "message")
	keep, _ := postNote(t, author, "keep me")["msg_id"].(string)
	readType(t, watcher, "message")
	thread := putCard(t, e, tid, id, lobby, "HUM-2", hub.WUIBox, 0, time.Now().UTC())

	code, out := call(t, e, tid, http.MethodPut, "/v1/messages/"+id+"/archive", "HUM-1", nil)
	if code != http.StatusOK {
		t.Fatalf("archive: %d %v", code, out)
	}
	if f := readType(t, watcher, "topic_archived"); f["msg_id"] != id || f["archived"] != true || f["task_id"] != lobby {
		t.Fatalf("watcher frame: %v", f)
	}
	_, feed := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+lobby, "HUM-2", nil)
	rows, _ := feed["messages"].([]any)
	if len(rows) != 1 {
		t.Fatalf("lobby feed after archive: %d rows %v", len(rows), feed)
	}

	code, out = call(t, e, tid, http.MethodDelete, "/v1/messages/"+id+"/topic", "HUM-1", nil)
	if code != http.StatusOK || out["deleted"] != float64(2) {
		t.Fatalf("delete: %d %v", code, out)
	}
	f := readType(t, watcher, "topic_deleted")
	ids, _ := f["msg_ids"].([]any)
	if f["msg_id"] != id || len(ids) != 2 {
		t.Fatalf("delete frame: %v", f)
	}
	if has(t, e, tid, id) || has(t, e, tid, thread) || !has(t, e, tid, keep) {
		t.Fatal("lobby delete removed the wrong rows")
	}
}

// An issue's discussion keeps its own lifecycle.
func TestTopicArchiveIssueRefused(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	ctx, now := context.Background(), time.Now().UTC()
	is := e.st.(store.Issues)
	if _, err := is.CreateIssueLabel(ctx, store.IssueLabel{TenantID: tid, LabelID: store.IssueEpicLabel, Name: store.IssueEpicLabel, CreatedBy: "HUM-1"}, now); err != nil {
		t.Fatal(err)
	}
	task := uuidV4()
	if _, err := is.CreateIssue(ctx, store.Issue{TenantID: tid, Title: "Epic", Priority: 2, Labels: []string{store.IssueEpicLabel},
		TaskID: task, CreatedBy: "HUM-1"}, now); err != nil {
		t.Fatal(err)
	}
	card := putCard(t, e, tid, task, "", "HUM-1", hub.WUIBox, 1, now)
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/messages/"+card+"/topic", "HUM-8", nil); code != http.StatusConflict || out["error"] != "issue_topic" {
		t.Fatalf("issue topic delete: %d %v", code, out)
	}
	if !has(t, e, tid, card) {
		t.Fatal("the refusal deleted the issue's card")
	}
}

func TestTopicArchivePreflight(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	for _, p := range []string{"/archive", "/topic"} {
		req, _ := http.NewRequest(http.MethodOptions, e.url(tid)+"/v1/messages/"+uuidV4()+p, nil)
		req.Header.Set("Origin", wuiOrigin)
		req.Header.Set("Access-Control-Request-Method", "DELETE")
		resp, err := e.client.Do(req)
		if err != nil {
			t.Fatal(err)
		}
		resp.Body.Close()
		if resp.StatusCode != http.StatusNoContent || resp.Header.Get("Access-Control-Allow-Methods") != "PUT, DELETE" {
			t.Fatalf("preflight %s: %d %q", p, resp.StatusCode, resp.Header.Get("Access-Control-Allow-Methods"))
		}
	}
}

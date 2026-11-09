package hub_test

import (
	"context"
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-4993, SPL-4991, SPL-4992 (owner HUM-10, msg f305bf70: "All four: fold,
// kind change, priority, delete"). The rest of a person's input stops at the
// archive too, each route with a live topic as its control.

// archivedRoute is one call on a topic with a card and two replies of HUM-1.
type archivedRoute struct {
	name   string
	method string
	path   func(task, card, r1, r2 string) string
	body   map[string]any
	want   int
}

var archivedRoutes = []archivedRoute{
	{"kind change", http.MethodPatch, func(_, _, r1, _ string) string { return "/v1/messages/" + r1 + "/kind" }, map[string]any{"kind": "task"}, http.StatusOK},
	{"priority", http.MethodPut, func(task, _, _, _ string) string { return "/v1/topics/" + task + "/priority" }, map[string]any{"priority": 2}, http.StatusOK},
	{"delete a reply", http.MethodDelete, func(_, _, _, r2 string) string { return "/v1/messages/" + r2 }, nil, http.StatusNoContent},
	{"delete the topic", http.MethodDelete, func(_, card, _, _ string) string { return "/v1/messages/" + card + "/topic" }, nil, http.StatusOK},
}

func topicOfThree(t *testing.T, a archivedTopic, task string) (card, r1, r2, r3 string) {
	t.Helper()
	post := func(isParent int) string {
		f := a.post(map[string]any{"task_id": task, "is_parent": isParent})
		if f.Type != "ack" {
			t.Fatalf("post: %+v", f)
		}
		return f.MsgID
	}
	return post(1), post(0), post(0), post(0)
}

func TestPersonInputRoutesOnArchivedTopicAreRefused(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	a := archivedTopic{e: e, tid: tid, w: dialWUI(t, e, tid, "HUM-1")}
	dead, live := uuidV4(), uuidV4()
	card, r1, r2, r3 := topicOfThree(t, a, dead)
	lCard, l1, l2, l3 := topicOfThree(t, a, live)
	archive := "/v1/messages/" + card + "/archive"
	if code, out := call(t, e, tid, http.MethodPut, archive, "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("archive: %d %v", code, out)
	}
	fold := map[string]any{"into": r2}
	if code, out := call(t, e, tid, http.MethodPost, "/v1/messages/"+r3+"/merge", "HUM-1", fold); code != http.StatusConflict || out["error"] != "topic_archived" {
		t.Errorf("fold on archived: %d %v, want 409 topic_archived", code, out)
	}
	if !has(t, e, tid, r3) {
		t.Error("the refused fold removed its source")
	}
	if code, out := call(t, e, tid, http.MethodPost, "/v1/messages/"+l3+"/merge", "HUM-1", map[string]any{"into": l2}); code != http.StatusOK {
		t.Errorf("fold on live: %d %v, want 200", code, out)
	}
	for _, rt := range archivedRoutes {
		if code, out := call(t, e, tid, rt.method, rt.path(dead, card, r1, r2), "HUM-1", rt.body); code != http.StatusConflict || out["error"] != "topic_archived" {
			t.Errorf("%s on archived: %d %v, want 409 topic_archived", rt.name, code, out)
		}
		if code, out := call(t, e, tid, rt.method, rt.path(live, lCard, l1, l2), "HUM-1", rt.body); code != rt.want {
			t.Errorf("%s on live: %d %v, want %d", rt.name, code, out, rt.want)
		}
	}
	if !has(t, e, tid, r2) || !has(t, e, tid, card) {
		t.Error("a refused delete removed its rows")
	}
	// Unarchive stays the way to reach Delete.
	if code, out := call(t, e, tid, http.MethodDelete, archive, "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("unarchive: %d %v", code, out)
	}
	for _, rt := range archivedRoutes {
		if code, out := call(t, e, tid, rt.method, rt.path(dead, card, r1, r2), "HUM-1", rt.body); code != rt.want {
			t.Errorf("%s after unarchive: %d %v, want %d", rt.name, code, out, rt.want)
		}
	}
}

// The Archive offers no Delete, and the card's own answer agrees: no button
// leads to the refusal.
func TestArchivedTopicIsNotOfferedDelete(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	card := putCard(t, e, tid, uuidV4(), "", "HUM-1", hub.WUIBox, 1, time.Now().UTC())
	size := "/v1/view/messages/" + card + "/topic"
	if _, out := call(t, e, tid, http.MethodGet, size, "HUM-1", nil); out["can_delete"] != true {
		t.Fatalf("live card: %v, want can_delete", out)
	}
	if code, out := call(t, e, tid, http.MethodPut, "/v1/messages/"+card+"/archive", "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("archive: %d %v", code, out)
	}
	if _, out := call(t, e, tid, http.MethodGet, size, "HUM-1", nil); out["can_delete"] != false {
		t.Errorf("archived card: %v, want no can_delete", out)
	}
	if _, out := call(t, e, tid, http.MethodGet, "/v1/view/archived", "HUM-1", nil); out["cards"].([]any)[0].(map[string]any)["can_delete"] != false {
		t.Errorf("archive list: %v, want no can_delete", out)
	}
}

func (g moveRig) mergeTopic(t *testing.T, card string, body map[string]any) (int, map[string]any) {
	t.Helper()
	return call(t, g.e, g.tid, http.MethodPost, "/v1/messages/"+card+"/merge-topic", "HUM-1", body)
}

func (g moveRig) putIn(t *testing.T, task, parent string, isParent int) string {
	t.Helper()
	return putCard(t, g.e, g.tid, task, parent, "HUM-1", hub.WUIBox, isParent, time.Now().UTC().Add(time.Minute))
}

func (g moveRig) archiveCard(t *testing.T, card string) string {
	t.Helper()
	path := "/v1/messages/" + card + "/archive"
	if code, out := call(t, g.e, g.tid, http.MethodPut, path, "HUM-2", nil); code != http.StatusOK {
		t.Fatalf("archive: %d %v", code, out)
	}
	return path
}

func (g moveRig) anyArchived(t *testing.T, id string) bool {
	t.Helper()
	closed, err := g.e.st.AnyTopicArchived(context.Background(), g.tid, lobby, []string{id})
	if err != nil {
		t.Fatal(err)
	}
	return closed
}

// SPL-4991: the door reads the rows' stored home, so a thread opened on a
// reply and a child of the archived topic both stay out, a forged from_task
// too; unarchive is the control.
func TestMergeUndoIntoArchivedTopicIsRefused(t *testing.T) {
	cases := map[string]func(t *testing.T, g moveRig) string{
		"a thread on a reply": func(t *testing.T, g moveRig) string { return g.putIn(t, g.r3, g.T, 1) },
		"a child topic":       func(t *testing.T, g moveRig) string { return g.putIn(t, uuidV4(), g.T, 1) },
	}
	for name, mk := range cases {
		t.Run(name, func(t *testing.T) {
			g := moveEnv(t)
			src := mk(t, g)
			code, out := g.mergeTopic(t, src, map[string]any{"to_task": g.U})
			if code != http.StatusOK {
				t.Fatalf("merge: %d %v", code, out)
			}
			path := g.archiveCard(t, g.card)
			undo := map[string]any{"undo": out["undo"]}
			if c, o := g.mergeTopic(t, src, undo); c != http.StatusConflict || o["error"] != "topic_archived" {
				t.Errorf("undo: %d %v, want 409 topic_archived", c, o)
			}
			forged := map[string]any{"undo": map[string]any{"from_task": uuidV4(), "msg_ids": out["msg_ids"]}}
			if c, o := g.mergeTopic(t, src, forged); c != http.StatusConflict {
				t.Errorf("undo with a forged from_task: %d %v, want 409", c, o)
			}
			if c, o := call(t, g.e, g.tid, http.MethodDelete, path, "HUM-2", nil); c != http.StatusOK {
				t.Fatalf("unarchive: %d %v", c, o)
			}
			if c, o := g.mergeTopic(t, src, undo); c != http.StatusOK {
				t.Errorf("undo after unarchive: %d %v, want 200", c, o)
			}
		})
	}
}

// SPL-4992: an archived topic does not merge away and take the live one down.
func TestMergeOfArchivedTopicLeavesTargetOpen(t *testing.T) {
	g := moveEnv(t)
	path := g.archiveCard(t, g.card)
	if c, o := g.mergeTopic(t, g.card, map[string]any{"to_task": g.U}); c != http.StatusConflict || o["error"] != "topic_archived" {
		t.Fatalf("merge an archived topic: %d %v, want 409 topic_archived", c, o)
	}
	if g.anyArchived(t, g.U) {
		t.Error("the refused merge closed the live target")
	}
	if c, o := call(t, g.e, g.tid, http.MethodDelete, path, "HUM-2", nil); c != http.StatusOK {
		t.Fatalf("unarchive: %d %v", c, o)
	}
	if c, o := g.mergeTopic(t, g.card, map[string]any{"to_task": g.U}); c != http.StatusOK {
		t.Errorf("merge after unarchive: %d %v, want 200", c, o)
	}
}

// N6: the opening row says whose child a topic is. A live topic with one
// stray row naming an archived parent stays open; the same parent on the
// opening row is a child, and closes.
func TestStrayParentRowDoesNotCloseLiveTopic(t *testing.T) {
	g := moveEnv(t)
	g.putIn(t, g.U, g.T, 0)
	child := uuidV4()
	g.putIn(t, child, g.T, 1)
	g.archiveCard(t, g.card)
	if g.anyArchived(t, g.U) {
		t.Error("a live topic with one stray parent row reads archived")
	}
	if !g.anyArchived(t, child) {
		t.Error("control: a topic opened under the archived parent reads live")
	}
}

// W1: a live lobby message folded into an archived lobby card adds to the
// archive: both rows share the lobby task, so the kept row is its own door.
func TestFoldIntoArchivedLobbyCardIsRefused(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	c := dialMember(t, e, tid, "HUM-1", "HUM-1")
	older, _ := postNote(t, c, "archived card")["msg_id"].(string)
	newer, _ := postNote(t, c, "live card")["msg_id"].(string)
	if code, out := call(t, e, tid, http.MethodPut, "/v1/messages/"+older+"/archive", "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("archive: %d %v", code, out)
	}
	if code, out := merge(t, e, tid, newer, older, "HUM-1"); code != http.StatusConflict || out["error"] != "topic_archived" {
		t.Errorf("fold into archived: %d %v, want 409 topic_archived", code, out)
	}
	if !has(t, e, tid, newer) {
		t.Error("the refused fold removed its source")
	}
}

// W2: a topic merged into a child keeps its older received_at and has no
// parent; the child's own opening row still says whose child it is.
func TestChildWithOlderMergedRowStaysUnderArchivedParent(t *testing.T) {
	g := moveEnv(t)
	child, at := uuidV4(), time.Now().UTC().Add(time.Minute)
	id := uuidV4()
	if _, err := g.e.st.InsertMessage(context.Background(), store.Message{TenantID: g.tid, MsgID: id, TaskID: child, ParentTaskID: g.T, Channel: "devel", IsParent: 1,
		TS: at, FromBox: hub.WUIBox, FromID: "HUM-1", ToBox: hub.WUIBox, ToID: "ALL-0", Kind: "note", Body: "child " + id,
		Files: []byte(`[]`), Msg: []byte(`{"v":1}`), Env: []byte(`{"id":"` + id + `"}`),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour)}); err != nil {
		t.Fatal(err)
	}
	if code, out := call(t, g.e, g.tid, http.MethodPost, "/v1/messages/"+g.uCard+"/merge-topic", "HUM-2", map[string]any{"to_task": child}); code != http.StatusOK {
		t.Fatalf("merge: %d %v", code, out)
	}
	if g.row(t, g.uCard).TaskID != child {
		t.Fatal("control: the older topic did not move into the child")
	}
	g.archiveCard(t, g.card)
	if !g.anyArchived(t, child) {
		t.Error("a child with an older merged row reads live under its archived parent")
	}
}

// archivedChild is a live parent g.card with an archived child topic.
func (g moveRig) archivedChild(t *testing.T) (childCard string) {
	t.Helper()
	child := uuidV4()
	childCard = g.putIn(t, child, g.T, 1)
	g.archiveCard(t, childCard)
	return childCard
}

// W3: taking a live parent's whole topic takes its archived child with it.
func TestTopicWritesRefuseAnArchivedChild(t *testing.T) {
	g := moveEnv(t)
	childCard := g.archivedChild(t)
	if code, out := call(t, g.e, g.tid, http.MethodDelete, "/v1/messages/"+g.card+"/topic", "HUM-1", nil); code != http.StatusConflict || out["error"] != "topic_archived" {
		t.Errorf("delete over an archived child: %d %v, want 409 topic_archived", code, out)
	}
	if !has(t, g.e, g.tid, childCard) {
		t.Error("the refused delete removed the archived child")
	}
	if code, out := g.mergeTopic(t, g.card, map[string]any{"to_task": g.U}); code != http.StatusConflict || out["error"] != "topic_archived" {
		t.Errorf("merge over an archived child: %d %v, want 409 topic_archived", code, out)
	}
}

// W4: can_delete says what DELETE will answer, in both directions.
func TestCanDeleteReadsTheWholeTopic(t *testing.T) {
	g := moveEnv(t)
	size := func(card string) any {
		_, out := call(t, g.e, g.tid, http.MethodGet, "/v1/view/messages/"+card+"/topic", "HUM-1", nil)
		return out["can_delete"]
	}
	if size(g.card) != true {
		t.Fatal("control: a live topic is not offered delete")
	}
	child := uuidV4()
	childCard := g.putIn(t, child, g.T, 1)
	g.archiveCard(t, childCard)
	if size(g.card) != false {
		t.Error("a parent over an archived child is offered delete")
	}
	h := moveEnv(t)
	liveChild := h.putIn(t, uuidV4(), h.T, 1)
	h.archiveCard(t, h.card)
	_, out := call(t, h.e, h.tid, http.MethodGet, "/v1/view/messages/"+liveChild+"/topic", "HUM-1", nil)
	if out["can_delete"] != false {
		t.Errorf("a child under an archived parent: %v, want no can_delete", out)
	}
}

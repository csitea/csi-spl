package hub_test

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// SPL-4954 (owner HUM-10, msg 51465f86: "the humans should not be able to
// insert any input anymore to the archived discussions"). Every human route
// that adds to a topic is refused while its card is archived, unarchive takes
// input again, and an agent still posts (spec 041 §3.1).

type archivedTopic struct {
	e           *env
	tid         string
	task        string
	card, reply string
	liveTask    string
	liveReply   string
	w           *wuiClient
	archive     string
}

func newArchivedTopic(t *testing.T) archivedTopic {
	t.Helper()
	e := archiveEnv(t)
	tid, _ := e.tenant()
	now := time.Now().UTC()
	a := archivedTopic{e: e, tid: tid, task: uuidV4(), liveTask: uuidV4()}
	a.card = putCard(t, e, tid, a.task, "", "HUM-1", hub.WUIBox, 1, now)
	a.reply = putCard(t, e, tid, a.task, "", "HUM-1", hub.WUIBox, 0, now.Add(time.Second))
	putCard(t, e, tid, a.liveTask, "", "HUM-1", hub.WUIBox, 1, now.Add(2*time.Second))
	a.liveReply = putCard(t, e, tid, a.liveTask, "", "HUM-1", hub.WUIBox, 0, now.Add(3*time.Second))
	a.archive = "/v1/messages/" + a.card + "/archive"
	if code, out := call(t, e, tid, http.MethodPut, a.archive, "HUM-1", nil); code != http.StatusOK || out["archived"] != true {
		t.Fatalf("archive: %d %v", code, out)
	}
	a.w = dialWUI(t, e, tid, "HUM-1")
	return a
}

// post sends one browser frame, a fresh msg_id unless extra names one, and
// answers the ack or the refusal frame.
func (a archivedTopic) post(extra map[string]any) wuiFrame {
	f := map[string]any{"type": "send", "msg_id": uuidV4(), "kind": "note", "body": "after the archive", "is_parent": 0, "channel": "lobby"}
	for k, v := range extra {
		f[k] = v
	}
	a.w.send(f)
	return a.w.readAny("ack", "error")
}

func TestHumanWriteToArchivedTopicIsRefused(t *testing.T) {
	a := newArchivedTopic(t)
	sha := strings.Repeat("ab", 32)
	cases := []struct {
		name  string
		frame map[string]any
	}{
		{"reply", map[string]any{"task_id": a.task}},
		{"reply on the card's own id", map[string]any{"task_id": a.card}},
		{"reply naming the archived topic as its parent", map[string]any{"task_id": uuidV4(), "parent_task_id": a.task}},
		{"a thread on a reply of the archived topic", map[string]any{"task_id": a.reply}},
		{"poll answer", map[string]any{"task_id": a.task, "body": "Poll: " + a.card + "\nAnswer: A yes"}},
		{"attachment", map[string]any{"task_id": a.task, "files": []map[string]any{{"file_id": sha, "sha256": sha, "name": "a.txt", "bytes": 1}}}},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			f := a.post(c.frame)
			if f.Type != "error" || f.Error != "topic_archived" {
				t.Fatalf("want error topic_archived, got %+v", f)
			}
			if has(t, a.e, a.tid, f.MsgID) {
				t.Fatalf("the refused message %s was stored", f.MsgID)
			}
		})
	}
}

// The control: the same frames on a live topic land, so the refusals above
// come from the archive and nothing else.
func TestHumanWriteToLiveTopicStillLands(t *testing.T) {
	a := newArchivedTopic(t)
	for _, frame := range []map[string]any{{"task_id": a.liveTask}, {"task_id": a.liveReply}, {"task_id": uuidV4(), "parent_task_id": a.liveTask}} {
		f := a.post(frame)
		if f.Type != "ack" || !has(t, a.e, a.tid, f.MsgID) {
			t.Fatalf("live topic %v: %+v", frame, f)
		}
	}
}

// A reply stored just before the archive whose ack was lost: the browser's
// resend of the SAME msg_id acks, it adds nothing to the topic.
func TestArchivedTopicResendOfStoredMessageAcks(t *testing.T) {
	a := newArchivedTopic(t)
	if code, _ := call(t, a.e, a.tid, http.MethodDelete, a.archive, "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("unarchive: %d", code)
	}
	frame := map[string]any{"msg_id": uuidV4(), "task_id": a.task}
	if f := a.post(frame); f.Type != "ack" {
		t.Fatalf("first send: %+v", f)
	}
	if code, _ := call(t, a.e, a.tid, http.MethodPut, a.archive, "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("re-archive: %d", code)
	}
	if f := a.post(frame); f.Type != "ack" {
		t.Fatalf("resend of a stored message: %+v", f)
	}
}

func TestUnarchivedTopicTakesInputAgain(t *testing.T) {
	a := newArchivedTopic(t)
	if f := a.post(map[string]any{"task_id": a.task}); f.Error != "topic_archived" {
		t.Fatalf("while archived: %+v", f)
	}
	if code, _ := call(t, a.e, a.tid, http.MethodDelete, a.archive, "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("unarchive: %d", code)
	}
	f := a.post(map[string]any{"task_id": a.task})
	if f.Type != "ack" || !has(t, a.e, a.tid, f.MsgID) {
		t.Fatalf("after unarchive: %+v", f)
	}
	if code, out := call(t, a.e, a.tid, http.MethodPut, "/v1/messages/"+a.reply+"/reactions", "HUM-1", map[string]any{"emoji": "👍"}); code != http.StatusOK {
		t.Fatalf("react after unarchive: %d %v", code, out)
	}
}

// An archived lobby card: its thread lives under task_id = the card's msg_id.
func TestHumanReplyInArchivedLobbyCardThreadIsRefused(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	card := putCard(t, e, tid, lobby, "", "HUM-1", hub.WUIBox, 1, time.Now().UTC())
	w := dialWUI(t, e, tid, "HUM-1")
	send := func(task string) wuiFrame {
		w.send(map[string]any{"type": "send", "msg_id": uuidV4(), "task_id": task, "kind": "note", "body": "x", "is_parent": 0, "channel": "lobby"})
		return w.readAny("ack", "error")
	}
	if code, _ := call(t, e, tid, http.MethodPut, "/v1/messages/"+card+"/archive", "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("archive: %d", code)
	}
	if f := send(card); f.Error != "topic_archived" {
		t.Fatalf("reply in the archived card's thread: %+v", f)
	}
	// The lobby room itself is one shared topic and never closes with a card.
	if f := send(lobby); f.Type != "ack" {
		t.Fatalf("a post in the lobby room: %+v", f)
	}
}

func TestHumanEditReactMoveIntoArchivedTopicIsRefused(t *testing.T) {
	a := newArchivedTopic(t)
	refused := func(what string, code int, out map[string]any) {
		t.Helper()
		if code != http.StatusConflict || out["error"] != "topic_archived" {
			t.Errorf("%s: want 409 topic_archived, got %d %v", what, code, out)
		}
	}
	// A really sent reply: its stored envelope can be edited, so only the
	// archive stands in the way.
	if code, _ := call(t, a.e, a.tid, http.MethodDelete, a.archive, "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("unarchive: %d", code)
	}
	sent := a.post(map[string]any{"task_id": a.task})
	if sent.Type != "ack" {
		t.Fatalf("send before the archive: %+v", sent)
	}
	if code, _ := call(t, a.e, a.tid, http.MethodPut, a.archive, "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("re-archive: %d", code)
	}
	code, out := call(t, a.e, a.tid, http.MethodPatch, "/v1/messages/"+sent.MsgID, "HUM-1", map[string]any{"body": "edited"})
	refused("edit a reply", code, out)
	code, out = call(t, a.e, a.tid, http.MethodPut, "/v1/messages/"+a.reply+"/reactions", "HUM-1", map[string]any{"emoji": "👍"})
	refused("react", code, out)
}

// A target in a created channel: moveTarget refuses a lobby card anyway, so
// only here the archive is what stands in the way. Unarchive is the control.
func TestHumanMoveAndMergeIntoArchivedTopicAreRefused(t *testing.T) {
	g := moveEnv(t)
	archive := "/v1/messages/" + g.uCard + "/archive"
	if code, out := call(t, g.e, g.tid, http.MethodPut, archive, "HUM-2", nil); code != http.StatusOK {
		t.Fatalf("archive: %d %v", code, out)
	}
	into := map[string]any{"to_task": g.U}
	for what, path := range map[string]string{"move a reply in": g.r3 + "/move", "merge a topic in": g.card + "/merge-topic"} {
		code, out := call(t, g.e, g.tid, http.MethodPost, "/v1/messages/"+path, "HUM-1", into)
		if code != http.StatusConflict || out["error"] != "topic_archived" {
			t.Errorf("%s: want 409 topic_archived, got %d %v", what, code, out)
		}
	}
	if code, out := call(t, g.e, g.tid, http.MethodDelete, archive, "HUM-2", nil); code != http.StatusOK {
		t.Fatalf("unarchive: %d %v", code, out)
	}
	if code, out := call(t, g.e, g.tid, http.MethodPost, "/v1/messages/"+g.r3+"/move", "HUM-1", into); code != http.StatusOK {
		t.Fatalf("move after unarchive: %d %v", code, out)
	}
}

// A person's DM that names an archived topic is stored; its mirror, a person's
// row in that topic, is not.
func TestDMRefToArchivedTopicIsNotMirrored(t *testing.T) {
	r := newDMRefRig(t)
	topic := uuidV4()
	card := putCard(t, r.e, r.tid, topic, "", "HUM-1", hub.WUIBox, 1, time.Now().UTC().Add(-time.Minute))
	before := uuidV4()
	if id := r.dm(r.w1, uuidV4(), before, topic, "before"); r.row(before, id).RefTaskID != topic {
		t.Fatal("CONTROL: the claim on a live topic was dropped")
	}
	if code, out := call(t, r.e, r.tid, http.MethodPut, "/v1/messages/"+card+"/archive", "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("archive: %d %v", code, out)
	}
	after := uuidV4()
	id := r.dm(r.w1, uuidV4(), after, topic, "after")
	if v := r.row(after, id); v.RefTaskID != "" {
		t.Fatalf("the claim on an archived topic was kept: %q", v.RefTaskID)
	}
}

// spec 041 §3.1's reason stands: an agent that finishes after the archive
// still reports into the topic, which stays archived.
func TestAgentPostToArchivedTopicIsStored(t *testing.T) {
	a := newArchivedTopic(t)
	ctx := context.Background()
	box := a.e.box(a.tid, "box-a", "GRK-03")
	a.e.pin(a.tid, box)
	if _, err := box.c.Sync(ctx); err != nil {
		t.Fatal(err)
	}
	out, err := action.SendCtx(ctx, box.cfg, action.SendArgs{From: "GRK-03", To: hub.BroadcastID, ToBox: hub.WUIBox,
		TaskID: a.task, Kind: "note", Body: "the lane's last report", Hub: box.c})
	if err != nil {
		t.Fatalf("agent send: %v", err)
	}
	if !has(t, a.e, a.tid, out.MsgID) {
		t.Fatalf("the agent's post %s was not stored", out.MsgID)
	}
	at, _, err := a.e.st.TopicArchived(ctx, a.tid, a.task, lobby)
	if err != nil || at.IsZero() {
		t.Fatalf("the topic left the archive: at=%v err=%v", at, err)
	}
}

// A visitor's post is a person's input too (c-001 8b4fea18 on the owner's
// msg 51465f86): the embed route refuses the visitor's archived topic, nothing
// is stored, and Unarchive takes the next line.
func TestVisitorPostToArchivedTopicIsRefused(t *testing.T) {
	e := embedEnv(t, true, hub.ViewDoorOff)
	pg := pgOnly(t, e)
	tid, _ := e.tenant()
	embed := seedEmbed(t, pg, tid, true)
	owner := seat(t, e, tid, rbac.BizOwner) // before the mint: a new channel seats the staff there are
	tok, _ := mint(t, e, tid, embed)
	path := "/v1/embed/" + embed + "/messages"
	post := func(body string) (int, []byte) {
		return embedCall(t, e, tid, http.MethodPost, path, tok, solvedPost(t, e, tid, embed, tok, body))
	}
	if code, raw := post("first line"); code != http.StatusCreated {
		t.Fatalf("CONTROL: a live topic: %d %s", code, raw)
	}
	lines := readLines(t, e, tid, embed, tok)
	if len(lines.Messages) != 1 {
		t.Fatalf("after the first post: %+v", lines)
	}
	archive := "/v1/messages/" + lines.Messages[0].MsgID + "/archive"
	if code, out := call(t, e, tid, http.MethodPut, archive, owner, nil); code != http.StatusOK || out["archived"] != true {
		t.Fatalf("archive: %d %v", code, out)
	}
	code, raw := post("after the archive")
	if code != http.StatusConflict || !strings.Contains(string(raw), "topic_archived") {
		t.Fatalf("archived: got %d %s, want 409 topic_archived", code, raw)
	}
	if got := readLines(t, e, tid, embed, tok); len(got.Messages) != 1 {
		t.Fatalf("the refused line was stored: %+v", got)
	}
	if code, out := call(t, e, tid, http.MethodDelete, archive, owner, nil); code != http.StatusOK {
		t.Fatalf("unarchive: %d %v", code, out)
	}
	if code, raw := post("after the unarchive"); code != http.StatusCreated {
		t.Fatalf("unarchived: got %d %s, want 201", code, raw)
	}
}

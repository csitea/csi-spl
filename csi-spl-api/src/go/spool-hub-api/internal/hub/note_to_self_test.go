package hub_test

import (
	"context"
	"crypto/ed25519"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 042 "Note to self" (SPL-5372; owner HUM-10, t1 df36f210, msg
// 76800948): a person's post tagged only to the person reaches no agent and
// no fallback responder, and is stored with messages.note_to_self. The
// control, the same person tagging self and an agent, is delivered as
// before. Memory store, and Postgres with SPOOL_TEST_PG_DSN.
func TestNoteToSelfReachesNoAgent(t *testing.T) {
	r, b := aiRig(t)
	ctx := context.Background()
	const me = "HUM-7"
	if err := r.e.st.AddChannelHumans(ctx, r.tid, "drivers", []string{me}, r.human, time.Now()); err != nil {
		t.Fatal(err)
	}
	ws := dialMember(t, r.e, r.tid, "FirstName LastName", me)
	has := func(id string) bool { return strings.Contains(strings.Join(inboxIDs(t, b, "GRK-36"), ","), id) }

	note, both := "a5372000-0000-4000-8000-000000000001", "a5372000-0000-4000-8000-000000000002"
	noteTask, bothTask := "b5372000-0000-4000-8000-000000000001", "b5372000-0000-4000-8000-000000000002"
	toMe, toMeTask := "a5372000-0000-4000-8000-000000000003", "b5372000-0000-4000-8000-000000000003"
	threadFrame(t, ws, note, noteTask, "drivers", 1, "@"+me+" send the zip file on Friday")
	// The WUI sends a leading @tag as the addressee, the body without it.
	wsjson.Write(ctx, ws, map[string]any{"type": "send", "msg_id": toMe, "task_id": toMeTask, "kind": "note", //nolint:errcheck
		"channel": "drivers", "to": me, "body": "send the zip file to the customer", "is_parent": 1})
	if ack := readType(t, ws, "ack"); ack["type"] != "ack" {
		t.Fatalf("send to self: %v", ack)
	}
	threadFrame(t, ws, both, bothTask, "drivers", 1, "@"+me+" and @GRK-36 send the zip file") // CONTROL
	eventually(t, "GRK-36 got the control post (self + agent)", func() bool { return has(both) })
	watch(400*time.Millisecond, func() bool { return has(note) || has(toMe) })
	if has(note) || has(toMe) {
		t.Fatalf("a note to self reached GRK-36: %v", inboxIDs(t, b, "GRK-36"))
	}
	if len(r.pokes()) != 0 {
		t.Fatalf("a note to self fell back to the desk: pokes %v", r.pokes())
	}

	flag := func(task, id string) bool {
		t.Helper()
		rows, err := r.e.st.(interface {
			ViewTopic(context.Context, string, store.TopicMsgQuery) ([]store.ViewMsg, error)
		}).ViewTopic(ctx, r.tid, store.TopicMsgQuery{TaskID: task, Now: time.Now(), Limit: 10})
		if err != nil {
			t.Fatal(err)
		}
		for _, v := range rows {
			if v.MsgID == id {
				return v.NoteToSelf
			}
		}
		t.Fatalf("%s not stored in %s", id, task)
		return false
	}
	if !flag(noteTask, note) {
		t.Errorf("the note to self is stored without note_to_self")
	}
	if !flag(toMeTask, toMe) {
		t.Errorf("a post addressed to its author is stored without note_to_self")
	}
	if flag(bothTask, both) {
		t.Errorf("the control (self + agent) is stored as a note to self")
	}
}

// Spec 042 "Note to self", part B (owner HUM-10, f0fc6d7f answer at
// 11:51:26Z; poll 3193d41f answer C): a person's tag of their own linked
// second account, which is not in the channel, gets no "does not belong to
// this channel" note and is a note to self. CONTROL: an unlinked outsider in
// the same channel still gets the note.
func TestNoteToSelfLinkedAccount(t *testing.T) {
	_, key, _ := ed25519.GenerateKey(nil)
	e := followEnv(t, func(o *hub.Options) { o.WUIKey = key })
	tid, _ := e.tenant()
	ctx := context.Background()
	now := time.Now().UTC().Truncate(time.Microsecond)
	admit := func(sub string) string {
		t.Helper()
		h := e.st.(store.Humans)
		email := sub + "@example.com"
		if err := h.PutInvite(ctx, store.Invite{TenantID: tid, Email: email, Role: store.RoleDefault,
			InvitedBy: store.AdmittedOperator, ExpiresAt: now.Add(time.Hour)}, now); err != nil {
			t.Fatal(err)
		}
		id, err := h.Admit(ctx, store.Identity{Provider: "google", Subject: sub, Email: email}, tid, store.AdmitPolicy{}, now)
		if err != nil {
			t.Fatal(err)
		}
		return id
	}
	me, second, stranger := admit("author-"+randHex(4)), admit("second-"+randHex(4)), admit("stranger-"+randHex(4))
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "giks",
		Name: "giks", CreatedBy: me, CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	if err := e.st.AddChannelHumans(ctx, tid, "giks", []string{me}, me, now); err != nil {
		t.Fatal(err)
	}
	if err := e.st.(store.HumanLinks).LinkHumans(ctx, me, second, "c-308 for "+me, now); err != nil {
		t.Fatal(err)
	}
	r := privacyRig{e: e, tid: tid}
	ws := dialMember(t, e, tid, me, me)
	own, other := uuidV4(), uuidV4()
	threadFrame(t, ws, uuidV4(), own, "giks", 1, "@"+second+" status: send the zip file")
	threadFrame(t, ws, uuidV4(), other, "giks", 1, "@"+stranger+" status: send the zip file") // CONTROL
	if n := waitNotes(t, r, other, 1); len(n) != 1 {
		t.Fatalf("the unlinked outsider got %d notes, want 1", len(n))
	}
	if n := hubNotes(t, r, own); len(n) != 0 {
		t.Fatalf("a tag of one's own linked account got the non-member note: %s", n)
	}
	// The WUI sends a leading @tag as the addressee: to the linked account.
	toSecond := uuidV4()
	wsjson.Write(ctx, ws, map[string]any{"type": "send", "msg_id": uuidV4(), "task_id": toSecond, "kind": "note", //nolint:errcheck
		"channel": "giks", "to": second, "body": "status: send the zip file", "is_parent": 1})
	if ack := readType(t, ws, "ack"); ack["type"] != "ack" {
		t.Fatalf("send to the linked account: %v", ack)
	}
	for _, task := range []string{own, toSecond} {
		rows, err := e.st.(interface {
			ViewTopic(context.Context, string, store.TopicMsgQuery) ([]store.ViewMsg, error)
		}).ViewTopic(ctx, tid, store.TopicMsgQuery{TaskID: task, Now: time.Now(), Limit: 10})
		if err != nil || len(rows) != 1 || !rows[0].NoteToSelf {
			t.Fatalf("%s: the linked-account post is not stored as a note to self: %v %+v", task, err, rows)
		}
	}
	if n := hubNotes(t, r, toSecond); len(n) != 0 {
		t.Fatalf("a post to one's own linked account got the non-member note: %s", n)
	}
}

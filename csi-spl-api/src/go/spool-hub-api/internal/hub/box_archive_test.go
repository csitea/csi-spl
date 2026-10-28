package hub_test

import (
	"context"
	"encoding/json"
	"testing"
	"time"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// CLE-77869: a box agent archives a topic by its task id through the real
// front end (action.Archive == `spool archive`), the box twin of the
// browser's PUT/DELETE /v1/messages/{card}/archive. Every refusal is a
// control: remove its guard in box_archive.go and that case turns red.

// boxArchiveRig: HUM-1 opened topic T (a card addressed to box-b, so box-b
// reads it); box-b seats CLE-08, box-c seats CLE-09 and never saw T.
func boxArchiveRig(t *testing.T) (e *env, tid, task, card string, b, c *box) {
	t.Helper()
	e = archiveEnv(t)
	tid, _ = e.tenant()
	b = e.box(tid, "box-b", "CLE-08")
	c = e.box(tid, "box-c", "CLE-09")
	e.pin(tid, b)
	e.pin(tid, c)
	task = uuidV4()
	card = putCard(t, e, tid, task, "", "HUM-1", hub.WUIBox, 1, time.Now().UTC())
	return e, tid, task, card, b, c
}

func archiveAnswer(t *testing.T, raw json.RawMessage) map[string]any {
	t.Helper()
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("answer %s: %v", raw, err)
	}
	return out
}

func TestBoxArchiveTopic(t *testing.T) {
	e, tid, task, card, b, _ := boxArchiveRig(t)
	ctx := context.Background()
	watcher := dialMember(t, e, tid, "HUM-2", "HUM-2")
	wsjson.Write(ctx, watcher, map[string]string{"type": "subscribe", "task_id": task}) //nolint:errcheck
	readType(t, watcher, "subscribed")

	raw, err := action.Archive(ctx, b.cfg, action.ArchiveArgs{TaskID: task, As: "CLE-08", Hub: b.c})
	if err != nil {
		t.Fatalf("archive: %v", err)
	}
	out := archiveAnswer(t, raw)
	if out["msg_id"] != card || out["task_id"] != task || out["archived"] != true || out["archived_by"] != "CLE-08" {
		t.Fatalf("archive answer %v", out)
	}
	st, err := e.st.CardState(ctx, tid, card, time.Now())
	if err != nil || st.ArchivedAt.IsZero() || st.ArchivedBy != "CLE-08" {
		t.Fatalf("stored state %+v %v", st, err)
	}
	if f := readType(t, watcher, "topic_archived"); f["msg_id"] != card || f["archived"] != true {
		t.Fatalf("browser frame %v", f)
	}
	if got := listedTasks(t, e, tid, "HUM-2"); got[task] {
		t.Fatalf("archived topic still listed: %v", got)
	}

	// Unarchive brings it back, and the browser hears it.
	raw, err = action.Archive(ctx, b.cfg, action.ArchiveArgs{TaskID: task, As: "CLE-08", Unarchive: true, Hub: b.c})
	if err != nil || archiveAnswer(t, raw)["archived"] != false {
		t.Fatalf("unarchive: %s %v", raw, err)
	}
	if f := readType(t, watcher, "topic_archived"); f["archived"] != false {
		t.Fatalf("browser unarchive frame %v", f)
	}
	if got := listedTasks(t, e, tid, "HUM-2"); !got[task] {
		t.Fatalf("unarchived topic not listed: %v", got)
	}
}

func TestBoxArchiveRefusals(t *testing.T) {
	e, tid, task, card, b, c := boxArchiveRig(t)
	ctx := context.Background()
	refused := func(label, want string, in action.ArchiveArgs, bx *box) {
		t.Helper()
		in.Hub = bx.c
		if _, err := action.Archive(ctx, bx.cfg, in); hubToken(err) != want {
			t.Fatalf("%s: want %s, got %v", label, want, err)
		}
		if st, _ := e.st.CardState(ctx, tid, card, time.Now()); !st.ArchivedAt.IsZero() {
			t.Fatalf("%s archived the topic", label)
		}
	}
	// An agent this box does not seat, and a human id.
	refused("unannounced agent", hub.TokenFromNotAnnounced, action.ArchiveArgs{TaskID: task, As: "CLE-09"}, b)
	refused("human id", hub.TokenFromNotAnnounced, action.ArchiveArgs{TaskID: task, As: "HUM-1"}, b)
	// A box that never saw the topic: it reads as absent.
	refused("unread topic", "not_found", action.ArchiveArgs{TaskID: task, As: "CLE-09"}, c)
	refused("unknown task", "not_found", action.ArchiveArgs{TaskID: uuidV4(), As: "CLE-08"}, b)
	refused("the lobby", "not_a_card", action.ArchiveArgs{TaskID: lobby, As: "CLE-08"}, b)

	// The workspace setting: admins never lets a box; starter only the box
	// that sent the card (HUM-1's browser did, so box-b is refused).
	ts := e.st.(store.TenantSettings)
	for _, p := range []string{store.ArchivePolicyAdmins, store.ArchivePolicyStarter} {
		if err := ts.SetTenantConfig(ctx, tid, store.TenantConfigPatch{TopicArchivePolicy: &p}); err != nil {
			t.Fatal(err)
		}
		refused("policy "+p, "not_allowed", action.ArchiveArgs{TaskID: task, As: "CLE-08"}, b)
	}
	// starter: the box that opened a topic may archive it.
	own := uuidV4()
	putCard(t, e, tid, own, "", "CLE-08", "box-b", 1, time.Now().UTC())
	if _, err := action.Archive(ctx, b.cfg, action.ArchiveArgs{TaskID: own, As: "CLE-08", Hub: b.c}); err != nil {
		t.Fatalf("starter box archive: %v", err)
	}

	// A delivered card reads: once box-c holds a delivery of it, everyone lets it archive.
	p := store.ArchivePolicyEveryone
	if err := ts.SetTenantConfig(ctx, tid, store.TenantConfigPatch{TopicArchivePolicy: &p}); err != nil {
		t.Fatal(err)
	}
	now := time.Now()
	if err := e.st.Enqueue(ctx, tid, card, "box-c", now, now.Add(time.Hour), 100); err != nil {
		t.Fatal(err)
	}
	if _, err := action.Archive(ctx, c.cfg, action.ArchiveArgs{TaskID: task, As: "CLE-09", Hub: c.c}); err != nil {
		t.Fatalf("delivered box archive: %v", err)
	}
}

// An issue's discussion keeps its own lifecycle, as in the browser route.
func TestBoxArchiveIssueRefused(t *testing.T) {
	e := archiveEnv(t)
	tid, _ := e.tenant()
	ctx, now := context.Background(), time.Now().UTC()
	b := e.box(tid, "box-b", "CLE-08")
	e.pin(tid, b)
	is := e.st.(store.Issues)
	if _, err := is.CreateIssueLabel(ctx, store.IssueLabel{TenantID: tid, LabelID: store.IssueEpicLabel, Name: store.IssueEpicLabel, CreatedBy: "HUM-1"}, now); err != nil {
		t.Fatal(err)
	}
	task := uuidV4()
	if _, err := is.CreateIssue(ctx, store.Issue{Discussions: []string{testDiscussion}, TenantID: tid, Title: "Epic", Priority: 2, Labels: []string{store.IssueEpicLabel},
		TaskID: task, CreatedBy: "HUM-1"}, now); err != nil {
		t.Fatal(err)
	}
	putCard(t, e, tid, task, "", "HUM-1", hub.WUIBox, 1, now)
	if _, err := action.Archive(ctx, b.cfg, action.ArchiveArgs{TaskID: task, As: "CLE-08", Hub: b.c}); hubToken(err) != "issue_topic" {
		t.Fatalf("issue topic archive: %v", err)
	}
}

// SPL-3965 (prd t1 topic bea3a4e6 in #spool-hub-devel): a channel topic whose
// card reached only a box that is gone answered not_found to the member
// desks that posted in it. A box whose acting agent is a member of the
// card's channel reads the card; a non-member, a private-scope topic and an
// agent dedicated to another scope still read it as absent.
func TestBoxArchiveChannelMember(t *testing.T) {
	e, tid, _, _, _, c := boxArchiveRig(t)
	ctx, now := context.Background(), time.Now().UTC()
	if err := e.st.CreateChannel(ctx, store.Channel{TenantID: tid, ChannelID: "devel", Name: "devel", CreatedBy: "HUM-1", CreatedAt: now}); err != nil {
		t.Fatal(err)
	}
	task := uuidV4()
	card := uuidV4()
	m := store.Message{TenantID: tid, MsgID: card, TaskID: task, Channel: "devel", IsParent: 1, TS: now,
		FromBox: hub.WUIBox, FromID: "HUM-1", ToBox: hub.WUIBox, ToID: "HUM-1", Kind: "note", Body: "archive me",
		Files: []byte(`[]`), Msg: []byte(`{"v":1}`), Env: []byte(`{"id":"` + card + `"}`), ReceivedAt: now, ExpiresAt: now.Add(24 * time.Hour)}
	if _, err := e.st.InsertMessage(ctx, m); err != nil {
		t.Fatal(err)
	}
	archive := func(label, want string) {
		t.Helper()
		_, err := action.Archive(ctx, c.cfg, action.ArchiveArgs{TaskID: task, As: "CLE-09", Hub: c.c})
		if hubToken(err) != want {
			t.Fatalf("%s: want %q, got %v", label, want, err)
		}
		st, _ := e.st.CardState(ctx, tid, card, time.Now())
		if got := !st.ArchivedAt.IsZero(); got != (want == "") {
			t.Fatalf("%s: archived=%v", label, got)
		}
		if got := !st.ArchivedAt.IsZero(); got {
			if _, err := action.Archive(ctx, c.cfg, action.ArchiveArgs{TaskID: task, As: "CLE-09", Unarchive: true, Hub: c.c}); err != nil {
				t.Fatalf("%s unarchive: %v", label, err)
			}
		}
	}
	archive("non-member", "not_found")
	if err := e.st.InviteChannelAgent(ctx, tid, "devel", "box-c", "CLE-09", now); err != nil {
		t.Fatal(err)
	}
	archive("member, card never delivered", "")

	ds := e.st.(store.DedicatedStore)
	if err := ds.SetPrivateScope(ctx, tid, store.ScopeTopic, task, true, now); err != nil {
		t.Fatal(err)
	}
	archive("member, private topic", "not_found")
	if err := ds.SetPrivateScope(ctx, tid, store.ScopeTopic, task, false, now); err != nil {
		t.Fatal(err)
	}
	if _, err := ds.SetDedicatedBinding(ctx, store.DedicatedBinding{TenantID: tid, AgentID: "CLE-09", BoxID: "box-c",
		ScopeType: store.ScopeChannel, ScopeID: "lobby", BoundBy: "HUM-1"}); err != nil {
		t.Fatal(err)
	}
	archive("member, dedicated elsewhere", "not_found")
}

package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-5284 (spec 041 archive-releases-work.md): an issue follows its
// discussion. Archiving the discussion closes its open issue (diss), tells
// every tab (an `issue` update frame) and leaves one comment on the issue
// naming the discussion; unarchiving reopens it the same way; deleting the
// discussion deletes the issue (an `issue` delete frame). Memory, and
// Postgres under SPOOL_TEST_PG_DSN.
func TestIssueFollowsDiscussionHub(t *testing.T) {
	_, key, _ := ed25519.GenerateKey(nil)
	e := newEnv(t, func(o *hub.Options) {
		o.ViewDoor = hub.ViewDoorOff
		o.LobbyTaskID = lobby
		o.ViewCORSOrigins = []string{wuiOrigin}
		o.Authorizer = roleOf{"HUM-8": rbac.BizOwner}
		o.SessionID = func(r *http.Request, _ string) (string, error) {
			if v := r.Header.Get(memberHeader); v != "" {
				return v, nil
			}
			return "", errors.New("no session")
		}
		o.WUIKey = key
	})
	tid, _ := e.tenant()
	ctx, now := context.Background(), time.Now().UTC()
	watcher := dialMember(t, e, tid, "HUM-2", "HUM-2")
	is := e.st.(store.Issues)
	T := uuidV4()
	card := putCard(t, e, tid, T, "", "HUM-1", hub.WUIBox, 1, now)
	i, err := is.CreateIssue(ctx, store.Issue{TenantID: tid, Title: "follows T", TaskID: uuidV4(), Discussions: []string{T}, CreatedBy: "HUM-1"}, now)
	if err != nil {
		t.Fatal(err)
	}
	wip := store.IssueWIP
	if _, err := is.UpdateIssue(ctx, tid, i.Number, store.IssuePatch{Status: &wip}, "HUM-1", now); err != nil {
		t.Fatal(err)
	}
	frame := func(op, status string) { issueFollowFrame(t, watcher, i.Number, op, status) }
	note := func(want string) { issueFollowNoteOnce(t, e, tid, "HUM-1", i.TaskID, T, want) }

	if code, out := call(t, e, tid, http.MethodPut, "/v1/messages/"+card+"/archive", "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("archive: %d %v", code, out)
	}
	frame("update", store.IssueDiss)
	note("Closed (diss, was wip)")

	if code, out := call(t, e, tid, http.MethodDelete, "/v1/messages/"+card+"/archive", "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("unarchive: %d %v", code, out)
	}
	frame("update", store.IssueWIP)
	note("Reopened as wip")

	if code, out := call(t, e, tid, http.MethodDelete, "/v1/messages/"+card+"/topic", "HUM-1", nil); code != http.StatusOK {
		t.Fatalf("delete: %d %v", code, out)
	}
	frame("delete", store.IssueWIP)
	if _, err := is.GetIssue(ctx, tid, i.Number); err == nil {
		t.Fatal("the issue outlived its deleted discussion")
	}
	expectNoFrame(t, watcher, "issue")
}

// issueFollowFrame reads the next `issue` frame on c and checks it. A second
// frame for the same follow would be the next one read, so the next check
// (or expectNoFrame at the end of a test) fails on it (R7 c-574 N2).
func issueFollowFrame(t *testing.T, c *websocket.Conn, number int, op, status string) {
	t.Helper()
	f := readType(t, c, "issue")
	row, _ := f["issue"].(map[string]any)
	if f["op"] != op || row["number"] != float64(number) || row["status"] != status {
		t.Fatalf("issue frame %v, want op %s status %s", f, op, status)
	}
}

// issueFollowNoteOnce fails unless the issue thread issueTask holds exactly
// one comment containing want that names /t/<discussion>.
func issueFollowNoteOnce(t *testing.T, e *env, tid, as, issueTask, discussion, want string) {
	t.Helper()
	code, out := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+issueTask, as, nil)
	if code != http.StatusOK {
		t.Fatalf("issue thread: %d %v", code, out)
	}
	rows, _ := out["messages"].([]any)
	n := 0
	for _, r := range rows {
		env, _ := r.(map[string]any)["env"].(map[string]any)
		m, _ := env["msg"].(map[string]any)
		if b, _ := m["body"].(string); strings.Contains(b, want) && strings.Contains(b, "/t/"+discussion) {
			n++
		}
	}
	if n != 1 {
		t.Fatalf("%d comments %q naming /t/%s in the issue thread, want 1: %v", n, want, discussion, rows)
	}
}

// followIssue makes a wip issue linking discussion task.
func followIssue(t *testing.T, e *env, tid, by, task string) store.Issue {
	t.Helper()
	ctx, now := context.Background(), time.Now().UTC()
	is := e.st.(store.Issues)
	i, err := is.CreateIssue(ctx, store.Issue{TenantID: tid, Title: "follows " + task, TaskID: uuidV4(), Discussions: []string{task}, CreatedBy: by}, now)
	if err != nil {
		t.Fatal(err)
	}
	wip := store.IssueWIP
	if i, err = is.UpdateIssue(ctx, tid, i.Number, store.IssuePatch{Status: &wip}, by, now); err != nil {
		t.Fatal(err)
	}
	return i
}

// R7 c-574 N1: a box agent's archive (spool archive) closes the issue, sends
// one frame and one comment naming the agent; its unarchive reopens it.
// Control: drop the afterIssueFollow call in box_archive.go and this fails.
func TestIssueFollowsBoxArchive(t *testing.T) {
	e := archiveEnv(t, func(o *hub.Options) { _, o.WUIKey, _ = ed25519.GenerateKey(nil) }) // the comment is signed with it
	tid, _ := e.tenant()
	b := e.box(tid, "box-b", "CLE-08")
	e.pin(tid, b)
	task := uuidV4()
	putCard(t, e, tid, task, "", "HUM-1", hub.WUIBox, 1, time.Now().UTC())
	ctx := context.Background()
	watcher := dialMember(t, e, tid, "HUM-2", "HUM-2")
	i := followIssue(t, e, tid, "HUM-1", task)
	if _, err := action.Archive(ctx, b.cfg, action.ArchiveArgs{TaskID: task, As: "CLE-08", Hub: b.c}); err != nil {
		t.Fatalf("archive: %v", err)
	}
	issueFollowFrame(t, watcher, i.Number, "update", store.IssueDiss)
	issueFollowNoteOnce(t, e, tid, "HUM-1", i.TaskID, task, "archived by CLE-08")
	if _, err := action.Archive(ctx, b.cfg, action.ArchiveArgs{TaskID: task, As: "CLE-08", Unarchive: true, Hub: b.c}); err != nil {
		t.Fatalf("unarchive: %v", err)
	}
	issueFollowFrame(t, watcher, i.Number, "update", store.IssueWIP)
	issueFollowNoteOnce(t, e, tid, "HUM-1", i.TaskID, task, "unarchived by CLE-08")
	expectNoFrame(t, watcher, "issue")
}

// R7 c-574 W1 (spec 041 FR-AW-004/005): a channel archive, unarchive and
// delete tell the tabs and comment like a topic's. Control: drop the
// afterIssueFollow call in retireChannel or handleUnarchiveChannel and this
// fails.
func TestIssueFollowsChannelHub(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	creator := seat(t, e, tid, "developer")
	ctx := context.Background()
	task := channelTopic(t, e, tid, creator, "followme")
	i := followIssue(t, e, tid, creator, task)
	watcher := dialMember(t, e, tid, creator, creator)

	if code, out := call(t, e, tid, http.MethodPut, "/v1/channels/followme/archive", creator, nil); code != http.StatusNoContent {
		t.Fatalf("archive: %d %v", code, out)
	}
	issueFollowFrame(t, watcher, i.Number, "update", store.IssueDiss)
	issueFollowNoteOnce(t, e, tid, creator, i.TaskID, task, "Closed (diss, was wip)")

	if code, out := call(t, e, tid, http.MethodPut, "/v1/channels/followme/unarchive", creator, nil); code != http.StatusOK {
		t.Fatalf("unarchive: %d %v", code, out)
	}
	issueFollowFrame(t, watcher, i.Number, "update", store.IssueWIP)
	issueFollowNoteOnce(t, e, tid, creator, i.TaskID, task, "Reopened as wip")
	if g, err := e.st.(store.Issues).GetIssue(ctx, tid, i.Number); err != nil || g.UpdatedBy != creator {
		t.Fatalf("reopened issue %+v %v, want updated_by %s", g, err, creator)
	}

	if code, out := call(t, e, tid, http.MethodDelete, "/v1/channels/followme", creator, nil); code != http.StatusNoContent {
		t.Fatalf("delete: %d %v", code, out)
	}
	issueFollowFrame(t, watcher, i.Number, "delete", store.IssueWIP)
	if _, err := e.st.(store.Issues).GetIssue(ctx, tid, i.Number); err == nil {
		t.Fatal("the issue outlived its deleted channel")
	}
	expectNoFrame(t, watcher, "issue")
}

// channelTopic creates channel ch as by and opens one topic in it.
func channelTopic(t *testing.T, e *env, tid, by, ch string) string {
	t.Helper()
	if code, out := call(t, e, tid, http.MethodPost, "/v1/channels", by,
		map[string]string{"channel": ch, "name": ch}); code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	now := time.Now().UTC()
	task, id := uuidV4(), uuidV4()
	if _, err := e.st.InsertMessage(context.Background(), store.Message{TenantID: tid, MsgID: id, TaskID: task, Channel: ch, IsParent: 1,
		TS: now, FromBox: hub.WUIBox, FromID: by, ToBox: "box-b", ToID: "CLE-07", Kind: "note", Body: "hello " + id,
		Files: []byte(`[]`), Msg: []byte(`{"v":1}`), Env: []byte(`{"id":"` + id + `"}`),
		ReceivedAt: now, ExpiresAt: now.Add(30 * 24 * time.Hour)}); err != nil {
		t.Fatal(err)
	}
	return task
}

// R7 c-574 W1: an admin's archive from the workspace settings
// (DELETE /v1/tenant/channels/{channel}) closes and tells like the
// creator's. Control: drop the afterIssueFollow call in
// handleArchiveTenantChannel and this fails.
func TestIssueFollowsTenantChannelArchive(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	creator := seat(t, e, tid, "developer")
	admin := seat(t, e, tid, rbac.Admin)
	task := channelTopic(t, e, tid, creator, "adminarch")
	i := followIssue(t, e, tid, creator, task)
	watcher := dialMember(t, e, tid, creator, creator)
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/tenant/channels/adminarch", admin, nil); code != http.StatusNoContent {
		t.Fatalf("admin archive: %d %v", code, out)
	}
	issueFollowFrame(t, watcher, i.Number, "update", store.IssueDiss)
	issueFollowNoteOnce(t, e, tid, creator, i.TaskID, task, "archived by "+admin)
	expectNoFrame(t, watcher, "issue")
}

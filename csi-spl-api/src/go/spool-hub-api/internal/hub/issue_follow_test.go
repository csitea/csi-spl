package hub_test

import (
	"context"
	"crypto/ed25519"
	"errors"
	"net/http"
	"strings"
	"testing"
	"time"

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
	frame := func(op, status string) {
		t.Helper()
		f := readType(t, watcher, "issue")
		row, _ := f["issue"].(map[string]any)
		if f["op"] != op || row["number"] != float64(i.Number) || row["status"] != status {
			t.Fatalf("issue frame %v, want op %s status %s", f, op, status)
		}
	}
	note := func(want string) {
		t.Helper()
		code, out := call(t, e, tid, http.MethodGet, "/v1/view/topics/"+i.TaskID, "HUM-1", nil)
		if code != http.StatusOK {
			t.Fatalf("issue thread: %d %v", code, out)
		}
		rows, _ := out["messages"].([]any)
		for _, r := range rows {
			env, _ := r.(map[string]any)["env"].(map[string]any)
			m, _ := env["msg"].(map[string]any)
			if b, _ := m["body"].(string); strings.Contains(b, want) && strings.Contains(b, "/t/"+T) {
				return
			}
		}
		t.Fatalf("no comment %q naming /t/%s in the issue thread: %v", want, T, rows)
	}

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
}

package hub_test

import (
	"context"
	"net/http"
	"sort"
	"testing"

	"github.com/coder/websocket/wsjson"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// SPL-6480 (HUM-24, csitea 5c9dcfe7; owner HUM-10 csitea c707c7a5 and t1
// 66f4500c): an issue comment is a message of the issue's topic, so its
// author edits it with PATCH /v1/messages/{id} like any message: a writer
// edits their own comment; a reader (no notes.send) and another author do
// not. Each saved edit is a row of the issue's History tab: who and when,
// no old text.
//
// CONTROLS: drop the message_revisions branch of issueHistorySQL (or the
// memory twin) and the history check goes red; drop rule 6 (isAuthor) in
// edit.go and the other-author check goes red; drop rule 4 (notes.send) and
// the reader check goes red.
func TestIssueCommentEdit(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	writer := seat(t, e, tid, rbac.Developer)
	other := seat(t, e, tid, rbac.Developer)
	reader := seat(t, e, tid, rbac.InternalAccountant) // topics.read only
	code, out := call(t, e, tid, http.MethodPost, "/v1/issues", writer, map[string]any{"title": "Comment edits"})
	if code != http.StatusCreated {
		t.Fatalf("create: %d %v", code, out)
	}
	issue := issueOf(t, out)
	task, _ := issue["task_id"].(string)

	c := dialMember(t, e, tid, writer, writer)
	wsjson.Write(context.Background(), c, map[string]any{"type": "send", "task_id": task, "channel": store.ChannelIssues, //nolint:errcheck
		"is_parent": 0, "body": "first take"})
	ack := readType(t, c, "ack")
	id, _ := ack["msg_id"].(string)
	if id == "" {
		t.Fatalf("comment not sent: %v", ack)
	}

	for _, who := range []struct{ name, as, token string }{
		{"reader", reader, "forbidden"},
		{"other author", other, "not_author"},
	} {
		code, out := patchEdit(t, e, tid, id, who.as, map[string]string{"body": "hijacked"})
		if code != http.StatusForbidden || out["error"] != who.token {
			t.Fatalf("%s editing the comment: %d %v (want 403 %s)", who.name, code, out, who.token)
		}
	}
	if code, out := patchEdit(t, e, tid, id, writer, map[string]string{"body": "second take"}); code != http.StatusOK || out["edited_by"] != writer {
		t.Fatalf("writer editing their own comment: %d %v (want 200)", code, out)
	}
	if got := storedBody(t, e, tid, id); got != "second take" {
		t.Fatalf("edit not stored: %q", got)
	}

	code, out = call(t, e, tid, http.MethodGet, "/v1/view/issues/"+issue["key"].(string)+"/history", writer, nil)
	if code != http.StatusOK {
		t.Fatalf("history: %d %v", code, out)
	}
	evs, _ := out["events"].([]any)
	var got []string
	for _, x := range evs {
		ev := x.(map[string]any)
		got = append(got, ev["event"].(string))
		if ev["event"] == store.IssueEventCommentEdited &&
			(ev["actor"] != writer || ev["msg_id"] != id || ev["at"] == "" || ev["new"] != nil || ev["old"] != nil) {
			t.Fatalf("comment edit row: %v", ev)
		}
	}
	// one second holds all three, and the comment's ts is whole seconds while
	// the create's is not: the set is the claim, the order is the store test's
	sort.Strings(got)
	if !sameKeys(got, store.IssueEventCommentEdited, store.IssueEventCommented, store.IssueEventCreated) {
		t.Fatalf("events: %v", got)
	}
}

package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// sheetIssue makes an epic and one issue with a description in tid.
func sheetIssue(t *testing.T, is store.Issues, tid, desc string) store.Issue {
	t.Helper()
	ctx, now := context.Background(), time.Now().UTC()
	if _, err := is.CreateIssueLabel(ctx, store.IssueLabel{TenantID: tid, LabelID: store.IssueEpicLabel, Name: store.IssueEpicLabel, CreatedBy: "HUM-1"}, now); err != nil {
		t.Fatal(err)
	}
	ep, err := is.CreateIssue(ctx, store.Issue{Discussions: []string{uuidV4()}, TenantID: tid, Title: "Epic", Labels: []string{store.IssueEpicLabel}, TaskID: uuidV4(), CreatedBy: "HUM-1"}, now)
	if err != nil {
		t.Fatal(err)
	}
	it, err := is.CreateIssue(ctx, store.Issue{Discussions: []string{uuidV4()}, TenantID: tid, Title: "with text", Description: desc, Parent: ep.Number, TaskID: uuidV4(), CreatedBy: "HUM-1"}, now)
	if err != nil {
		t.Fatal(err)
	}
	return it
}

// sheetDescOf is the description of key's row in a list body ("absent" if none).
func sheetDescOf(t *testing.T, body map[string]any, key string) any {
	t.Helper()
	list, _ := body["issues"].([]any)
	for _, x := range list {
		if row := x.(map[string]any); row["key"] == key {
			if v, ok := row["description"]; ok {
				return v
			}
			return "absent"
		}
	}
	t.Fatalf("%s not listed in %v", key, body)
	return nil
}

// P5-06: the browser's sheet reads no description on a store with the sheet
// read (Postgres; memory has one list read); the open issue's by-number read keeps the text.
// CONTROL: the same store's full list does carry it, so the blank is the
// projection, not a missing row.
func TestIssueSheetWithoutDescription(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	as := seat(t, e, tid, rbac.Developer)
	desc := "the long text " + strings.Repeat("x", 512)
	it := sheetIssue(t, e.st.(store.Issues), tid, desc)
	code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues", as, nil)
	if code != http.StatusOK {
		t.Fatalf("list: %d %v", code, out)
	}
	want := any(desc)
	if _, ok := e.st.(*store.Postgres); ok { // memory keeps one list read
		want = ""
	}
	if got := sheetDescOf(t, out, it.Key()); got != want {
		t.Fatalf("sheet description = %.40q, want %.40q", got, want)
	}
	code, out = call(t, e, tid, http.MethodGet, "/v1/view/issues/"+it.Key(), as, nil)
	if code != http.StatusOK || issueOf(t, out)["description"] != desc {
		t.Fatalf("by-number read lost the text: %d %.80v", code, out)
	}
	full, err := e.st.(store.Issues).ListIssues(context.Background(), tid)
	if err != nil || len(full) != 2 || full[0].Description != desc {
		t.Fatalf("CONTROL ListIssues: %v %d", err, len(full))
	}
}

// P5-06: an agent's `issue list` keeps the description (only the browser's
// sheet is narrow).
func TestAgentIssueListKeepsDescription(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	sa, err := a.c.Dial(ctx, wire.RoleBox)
	if err != nil {
		t.Fatal(err)
	}
	defer closeWait(sa)
	desc := "agent-visible text"
	it := sheetIssue(t, e.st.(store.Issues), tid, desc)
	raw, err := action.Issue(ctx, a.cfg, action.IssueArgs{Op: "list", As: "CLE-07", Hub: a.c})
	if err != nil {
		t.Fatal(err)
	}
	var out map[string]any
	if err := json.Unmarshal(raw, &out); err != nil {
		t.Fatalf("%v: %s", err, raw)
	}
	if got := sheetDescOf(t, out, it.Key()); got != desc {
		t.Fatalf("agent list description = %q, want %q", got, desc)
	}
}

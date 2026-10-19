package hub_test

import (
	"context"
	"encoding/json"
	"errors"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// SPL-2607: the agent op get (== `spool issue get`) answers an archived
// issue too, with archived and auto_closed, so a placer on another box can
// tell an epic the SPL-1729 auto-close archived from one a person closed
// (SPL-2558). A live issue answers as before, without either key; a deleted
// one stays not_found. Red control: on master the archived get answers
// not_found.
func TestAgentGetArchivedIssue(t *testing.T) {
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

	do := func(in action.IssueArgs) (map[string]any, error) {
		in.Hub, in.As = a.c, "CLE-07"
		in.Issue = withDefaultDiscussion(tid, in.Op, in.Issue)
		raw, err := action.Issue(ctx, a.cfg, in)
		out := map[string]any{}
		if err == nil {
			if jerr := json.Unmarshal(raw, &out); jerr != nil {
				t.Fatalf("reply %s: %v", raw, jerr)
			}
		}
		return out, err
	}
	mk := func(body string) string {
		t.Helper()
		out, err := do(action.IssueArgs{Op: "create", Issue: json.RawMessage(body)})
		if err != nil {
			t.Fatalf("create %s: %v", body, err)
		}
		return out["issue"].(map[string]any)["key"].(string)
	}
	set := func(ref, body string) {
		t.Helper()
		if _, err := do(action.IssueArgs{Op: "update", Ref: ref, Issue: json.RawMessage(body)}); err != nil {
			t.Fatalf("update %s %s: %v", ref, body, err)
		}
	}
	get := func(ref string) map[string]any {
		t.Helper()
		out, err := do(action.IssueArgs{Op: "get", Ref: ref})
		if err != nil {
			t.Fatalf("get %s: %v", ref, err)
		}
		return out["issue"].(map[string]any)
	}
	flags := func(i map[string]any) [2]any { return [2]any{i["archived"], i["auto_closed"]} }

	auto := mk(`{"title":"auto","kind":"epic"}`)
	autoKid := mk(`{"title":"last open","epic":"` + auto + `","status":"wip"}`)
	byHand := mk(`{"title":"by hand","kind":"epic"}`)
	handKid := mk(`{"title":"done first","epic":"` + byHand + `","status":"wip"}`)
	live := mk(`{"title":"live","epic":"` + byHand + `","status":"wip"}`)

	// The last open issue closes: the epic closes and archives by itself.
	set(autoKid, `{"status":"done"}`)
	if i := get(auto); flags(i) != [2]any{true, true} || i["status"] != "done" || i["kind"] != "epic" {
		t.Fatalf("auto-closed epic: %v", i)
	}
	if i := get(autoKid); flags(i) != [2]any{true, false} || i["epic"] != auto || i["kind"] != "issue" {
		t.Fatalf("its issue, archived with it: %v", i)
	}

	// CONTROL: a person closes an epic; its cascade archives it the same way.
	set(handKid, `{"status":"done"}`)
	set(byHand, `{"status":"done","cascade":true}`)
	if i := get(byHand); flags(i) != [2]any{true, false} {
		t.Fatalf("hand-closed epic reads auto-closed: %v", i)
	}
	if i := get(live); flags(i) != [2]any{true, false} || i["status"] != "done" {
		t.Fatalf("issue closed by the hand close: %v", i)
	}

	// A live issue answers as today: neither key.
	fresh := mk(`{"title":"fresh","kind":"epic"}`)
	if i := get(fresh); flags(i) != [2]any{nil, nil} {
		t.Fatalf("live issue carries the flags: %v", i)
	}
	// Unarchived, the auto-closed epic is live again and unflagged; archived
	// again by hand, it is no longer auto-closed.
	if _, err := do(action.IssueArgs{Op: "unarchive", Ref: auto}); err != nil {
		t.Fatal(err)
	}
	if i := get(auto); flags(i) != [2]any{nil, nil} {
		t.Fatalf("unarchived epic: %v", i)
	}
	if _, err := do(action.IssueArgs{Op: "archive", Ref: auto, Query: "cascade=yes"}); err != nil {
		t.Fatal(err)
	}
	if i := get(auto); flags(i) != [2]any{true, false} {
		t.Fatalf("epic archived by hand after its auto-close: %v", i)
	}
	// A deleted issue stays not_found.
	if _, err := do(action.IssueArgs{Op: "delete", Ref: fresh}); err != nil {
		t.Fatal(err)
	}
	var he *hubclient.HubError
	if _, err := do(action.IssueArgs{Op: "get", Ref: fresh}); !errors.As(err, &he) || he.Token != "not_found" {
		t.Fatalf("deleted issue get: %v", err)
	}
}

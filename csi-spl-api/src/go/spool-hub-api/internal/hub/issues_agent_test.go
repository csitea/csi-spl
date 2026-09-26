package hub_test

import (
	"context"
	"encoding/json"
	"errors"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/action"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hubclient"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/wire"
)

// specs/039 FR-008: an agent files and advances its work as issues over its
// own box socket, through the real front end (action.Issue == `spool issue`
// == the MCP tool), as itself - and only as an agent its box announced. A
// progress comment lands in the issue's discussion at reply level, so it
// is not a card in the #tasks feed. Browsers see every change live.
func TestAgentIssues(t *testing.T) {
	e := followEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	a := e.box(tid, "box-a", "CLE-07")
	e.pin(tid, a)
	sa, err := a.c.Dial(ctx, wire.RoleBox) // announces CLE-07
	if err != nil {
		t.Fatal(err)
	}
	defer sa.Close()
	watcher := dialMember(t, e, tid, "Tess", "HUM-1")

	do := func(in action.IssueArgs) (map[string]any, error) {
		in.Hub = a.c
		raw, err := action.Issue(ctx, a.cfg, in)
		out := map[string]any{}
		if err == nil {
			if jerr := json.Unmarshal(raw, &out); jerr != nil {
				t.Fatalf("reply %s: %v", raw, jerr)
			}
		}
		return out, err
	}
	hubErr := func(err error) string {
		var he *hubclient.HubError
		if errors.As(err, &he) {
			return he.Token
		}
		return ""
	}

	// Not announced by this box: refused before anything is written.
	if _, err := do(action.IssueArgs{Op: "create", As: "GRK-99", Issue: json.RawMessage(`{"title":"x"}`)}); hubErr(err) != wire.TokenFromNotAnnounced {
		t.Fatalf("unannounced agent: %v", err)
	}
	if _, err := do(action.IssueArgs{Op: "label", As: "CLE-07", Issue: json.RawMessage(`{"name":"infra"}`)}); err != nil {
		t.Fatal(err)
	}
	readType(t, watcher, "issue_label")
	out, err := do(action.IssueArgs{Op: "create", As: "CLE-07", Issue: json.RawMessage(
		`{"title":"Rotate the relay key","description":"spec: ...","priority":2,"level":2,"assignee":"CLE-07","labels":["infra"],"deadline":"2026-10-02T09:00:00Z"}`)})
	if err != nil {
		t.Fatal(err)
	}
	iss := out["issue"].(map[string]any)
	if iss["key"] != "SPL-1" || iss["created_by"] != "CLE-07" || iss["assignee"] != "CLE-07" {
		t.Fatalf("agent create %v", iss)
	}
	if f := readType(t, watcher, "issue"); f["op"] != "create" {
		t.Fatalf("browser frame %v", f)
	}
	if _, err := do(action.IssueArgs{Op: "create", As: "CLE-07", Issue: json.RawMessage(`{"title":"x","bogus":1}`)}); hubErr(err) != "bad_json" {
		t.Fatalf("unknown field: %v", err)
	}
	if _, err := do(action.IssueArgs{Op: "update", As: "CLE-07", Ref: "SPL-1", Issue: json.RawMessage(`{"status":"in_progress"}`)}); err != nil {
		t.Fatal(err)
	}
	if f := readType(t, watcher, "issue"); f["op"] != "update" || f["issue"].(map[string]any)["updated_by"] != "CLE-07" {
		t.Fatalf("update frame %v", f)
	}
	out, err = do(action.IssueArgs{Op: "list", As: "CLE-07", Query: "assignee=me&status=in_progress"})
	if err != nil || len(out["issues"].([]any)) != 1 {
		t.Fatalf("list mine: %v %v", err, out)
	}
	if _, err := do(action.IssueArgs{Op: "get", As: "CLE-07", Ref: "SPL-9"}); hubErr(err) != "not_found" {
		t.Fatalf("get missing: %v", err)
	}

	// Progress goes onto the issue, at reply level, in #tasks.
	out, err = do(action.IssueArgs{Op: "comment", As: "CLE-07", Ref: "SPL-1", Body: "key rotated on dev, prd next"})
	if err != nil || out["issue"] != "SPL-1" || out["task_id"] != iss["task_id"] {
		t.Fatalf("comment: %v %v", err, out)
	}
	msgs, _ := e.st.ViewTopic(ctx, tid, store.TopicMsgQuery{TaskID: iss["task_id"].(string), Now: time.Now()})
	if len(msgs) != 1 || msgs[0].IsParent != 0 {
		t.Fatalf("stored comment: %+v", msgs)
	}
	env, err := wire.ParseEnvelope(msgs[0].Env)
	if err != nil {
		t.Fatal(err)
	}
	if m, err := env.Inner(); err != nil || m.From != "CLE-07" || m.Body != "key rotated on dev, prd next" || env.Channel != "tasks" || env.FromBox != "box-a" {
		t.Fatalf("comment envelope: %+v %+v %v", env, m, err)
	}
	// Not a topic of any list the WUI draws (#tasks cards, the Topics tab)...
	for _, q := range []string{"?channel=tasks", ""} {
		if code, out := call(t, e, tid, "GET", "/v1/view/topics"+q, "HUM-1", nil); code != 200 || len(out["topics"].([]any)) != 0 {
			t.Fatalf("topics%s lists the issue's discussion: %d %v", q, code, out)
		}
	}
	// ...CONTROL: the store holds it as a #tasks topic; only the filter hides it.
	if rows, _ := e.st.ViewTopics(ctx, tid, store.TopicQuery{Now: time.Now(), Channel: "tasks"}); len(rows) != 1 {
		t.Fatalf("control: %+v", rows)
	}
	if rows, _ := e.st.ViewTopics(ctx, tid, store.TopicQuery{Now: time.Now(), Channel: "tasks", NoIssues: true}); len(rows) != 0 {
		t.Fatalf("store NoIssues: %+v", rows)
	}
	// The issue's own topic read still has it (the right pane).
	if code, out := call(t, e, tid, "GET", "/v1/view/topics/"+iss["task_id"].(string), "HUM-1", nil); code != 200 || len(out["messages"].([]any)) != 1 {
		t.Fatalf("issue topic read: %d %v", code, out)
	}
	if _, err := do(action.IssueArgs{Op: "comment", As: "CLE-07", Ref: "SPL-1", Body: "  "}); hubErr(err) != "bad_issue" {
		t.Fatalf("empty comment: %v", err)
	}
	if _, err := do(action.IssueArgs{Op: "drop", As: "CLE-07"}); err == nil {
		t.Fatal("unknown op accepted")
	}
}

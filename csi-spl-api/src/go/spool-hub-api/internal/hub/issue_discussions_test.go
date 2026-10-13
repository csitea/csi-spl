package hub_test

import (
	"context"
	"encoding/json"
	"net/http"
	"slices"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
	"github.com/csitea/csi-spl/spool-hub-api/internal/uid"
)

// testDiscussion is the topic a store-level create in these tests links
// (SPL-1593: every issue links at least one).
const testDiscussion = "0b1c2d3e-4f50-4617-8293-a4b5c6d7e8f9"

// withDefaultDiscussion gives an agent create with no discussions the
// tenant's default one (SPL-1593), so the older agent tests keep their shape.
func withDefaultDiscussion(tid, op string, raw json.RawMessage) json.RawMessage {
	if op != "create" || len(raw) == 0 {
		return raw
	}
	m := map[string]any{}
	if json.Unmarshal(raw, &m) != nil {
		return raw
	}
	if _, has := m["discussions"]; has {
		return raw
	}
	m["discussions"] = []string{store.IssueDiscussionDefault(tid)}
	out, _ := json.Marshal(m)
	return out
}

// discussionsOf is the issue's discussions on the wire.
func discussionsOf(t *testing.T, issue map[string]any) []map[string]any {
	t.Helper()
	raw, _ := issue["discussions"].([]any)
	out := make([]map[string]any, len(raw))
	for k, d := range raw {
		out[k], _ = d.(map[string]any)
	}
	return out
}

// lobbyTopic stores one #lobby card of topic task with body.
func lobbyTopic(t *testing.T, e *env, tid, task, body string) {
	t.Helper()
	at := time.Now().UTC()
	m := store.Message{TenantID: tid, MsgID: task, TaskID: task, Channel: store.ChannelLobby, TS: at,
		FromBox: "box-wui", FromID: "HUM-1", ToBox: "box-wui", ToID: "ALL-0", Kind: "note", Body: body,
		Files: []byte(`[]`), Msg: []byte(`{"v":1}`), EnvSig: "sig", Env: []byte(`{"env":1}`),
		ReceivedAt: at, ExpiresAt: at.Add(30 * 24 * time.Hour), IsParent: 1}
	if _, err := e.st.InsertMessage(context.Background(), m); err != nil {
		t.Fatal(err)
	}
}

// SPL-1593 (owner HUM-10, t1 fcf09921, msgs 3e75e13e, 9a8e4764, 62f96f94):
// a create needs at least one discussion of the tenant; the list and the
// single read carry the links; add and remove work, and the last one stays.
func TestIssueDiscussionsCreateLinkUnlink(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	talk := uid.New()
	lobbyTopic(t, e, tid, talk, "## Login breaks on mobile\n\nsteps ...")

	for _, bad := range []struct {
		name string
		ds   any
		code int
		tok  string
	}{
		{"none", []string{}, http.StatusBadRequest, "discussion_required"},
		{"not a topic id", []string{"SPL-1"}, http.StatusBadRequest, "bad_issue"},
		{"unknown topic", []string{uid.New()}, http.StatusBadRequest, "unknown_discussion"},
	} {
		code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "x", "discussions": bad.ds})
		if code != bad.code || out["error"] != bad.tok {
			t.Errorf("%s: %d %v, want %d %s", bad.name, code, out, bad.code, bad.tok)
		}
	}
	// Control: nothing was filed by the refusals.
	if code, out := call(t, e, tid, http.MethodGet, "/v1/view/issues", dev, nil); code != 200 || len(issueKeys(out)) != 0 {
		t.Fatalf("after the refusals: %d %v", code, issueKeys(out))
	}

	code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "Login", "discussions": []string{"https://x.example.com/t/" + talk}})
	one := issueOf(t, out)
	if ds := discussionsOf(t, one); code != http.StatusCreated || len(ds) != 1 || ds[0]["task_id"] != talk ||
		ds[0]["state"] != store.DiscussionLive || ds[0]["title"] != "Login breaks on mobile" || ds[0]["channel"] != store.ChannelLobby {
		t.Fatalf("create with a topic link: %d %v", code, out)
	}
	// An old `spool` sends no discussions field: the card's Source line links.
	code, out = call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "from a card",
		"description": "## Source\n/t/" + talk + "\n\n## Restart\n- key: <new>", "discussions": nil})
	if ds := discussionsOf(t, issueOf(t, out)); code != http.StatusCreated || len(ds) != 1 || ds[0]["task_id"] != talk {
		t.Fatalf("create from the card's source line: %d %v", code, out)
	}

	def := store.IssueDiscussionDefault(tid)
	code, out = call(t, e, tid, http.MethodPost, "/v1/issues/SPL-1/discussions", dev, map[string]any{"discussion": def})
	if ds := discussionsOf(t, issueOf(t, out)); code != 200 || len(ds) != 2 || ds[1]["task_id"] != def || ds[1]["state"] != store.DiscussionLive {
		t.Fatalf("link the backlog topic: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues/SPL-1/discussions", dev, map[string]any{"discussion": uid.New()}); code != http.StatusBadRequest || out["error"] != "unknown_discussion" {
		t.Fatalf("link an unknown topic: %d %v", code, out)
	}
	code, out = call(t, e, tid, http.MethodGet, "/v1/view/issues", dev, nil)
	if code != 200 {
		t.Fatalf("list: %d %v", code, out)
	}
	for _, raw := range out["issues"].([]any) {
		i := raw.(map[string]any)
		if want := map[string]int{"SPL-1": 2, "SPL-2": 1}[i["key"].(string)]; len(discussionsOf(t, i)) != want {
			t.Errorf("list %s discussions = %v, want %d", i["key"], i["discussions"], want)
		}
	}

	if code, out := call(t, e, tid, http.MethodDelete, "/v1/issues/SPL-1/discussions/"+talk, dev, nil); code != 200 || len(discussionsOf(t, issueOf(t, out))) != 1 {
		t.Fatalf("unlink one of two: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/issues/SPL-1/discussions/"+def, dev, nil); code != http.StatusConflict || out["error"] != "last_discussion" {
		t.Fatalf("unlink the last: %d %v, want 409 last_discussion", code, out)
	}
	if code, out := call(t, e, tid, http.MethodDelete, "/v1/issues/SPL-1/discussions/"+talk, dev, nil); code != http.StatusNotFound {
		t.Fatalf("unlink a topic it does not link: %d %v", code, out)
	}
	code, out = call(t, e, tid, http.MethodGet, "/v1/view/issues/SPL-1", dev, nil)
	if ds := discussionsOf(t, issueOf(t, out)); code != 200 || len(ds) != 1 || ds[0]["task_id"] != def || ds[0]["title"] != "Issue backlog" {
		t.Fatalf("single read after: %d %v", code, out)
	}
}

// A brief names a topic by its 8-hex short id (c-002, dispatch-fcf09921 msg
// c5c7d032): one match in the tenant links it; two never link either.
func TestIssueDiscussionShortID(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	dev := seat(t, e, tid, rbac.Developer)
	one := "5eed0001-0000-4000-8000-000000000001"
	twinA, twinB := "a1b2c3d4-0000-4000-8000-00000000000a", "a1b2c3d4-0000-4000-8000-00000000000b"
	for _, task := range []string{one, twinA, twinB} {
		lobbyTopic(t, e, tid, task, "topic "+task)
	}
	code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "short", "discussions": []string{"5eed0001"}})
	if ds := discussionsOf(t, issueOf(t, out)); code != http.StatusCreated || len(ds) != 1 || ds[0]["task_id"] != one {
		t.Fatalf("a unique short id: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "twins", "discussions": []string{"a1b2c3d4"}}); code != http.StatusBadRequest || out["error"] != "ambiguous_discussion" {
		t.Fatalf("an ambiguous short id: %d %v, want 400 ambiguous_discussion", code, out)
	}
	// From the card: the ambiguous one is left out, the unique one links.
	code, out = call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "card", "discussions": nil,
		"description": "## Source\n/t/a1b2c3d4\n\n- Topic: https://x.example.com/t/5eed0001 and /t/" + uid.New()})
	if ds := discussionsOf(t, issueOf(t, out)); code != http.StatusCreated || len(ds) != 1 || ds[0]["task_id"] != one {
		t.Fatalf("a card with an ambiguous, a unique and an unknown link: %d %v", code, out)
	}
	// A card none of whose links resolves, from a client that sends no
	// discussions field: the tenant's default (the rollout step,
	// legacyCreateDefault), never a guess between the twins.
	code, out = call(t, e, tid, http.MethodPost, "/v1/issues", dev, map[string]any{"title": "none", "discussions": nil,
		"description": "## Source\n/t/a1b2c3d4"})
	if ds := discussionsOf(t, issueOf(t, out)); code != http.StatusCreated || len(ds) != 1 || ds[0]["task_id"] != store.IssueDiscussionDefault(tid) {
		t.Fatalf("a card with only an ambiguous link: %d %v, want the default", code, out)
	}
}

// The backlog topic (owner msg e3c349e2) is posted once per tenant that links
// to it, and a second sweep posts nothing.
func TestIssueBacklogPostedOnce(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	ctx := context.Background()
	is := e.st.(store.Issues)
	if _, err := is.CreateIssue(ctx, store.Issue{TenantID: tid, Title: "old", TaskID: uid.New(), CreatedBy: "HUM-1",
		Discussions: []string{store.IssueBacklogID(tid)}}, time.Now()); err != nil {
		t.Fatal(err)
	}
	// The sweep covers every tenant in the store: on a shared Postgres other
	// tests' tenants count too, so assert on this tenant, not on the total.
	if n := e.srv.PostIssueBacklogs(ctx); n < 1 {
		t.Fatalf("first sweep posted %d, want at least this tenant's", n)
	}
	missing, err := e.st.(store.IssueDiscussions).TenantsMissingIssueBacklog(ctx)
	if err != nil || slices.Contains(missing, tid) {
		t.Fatalf("after the sweep the tenant still misses its backlog: %v %v", missing, err)
	}
	// A second sweep never lists this tenant again (its topic is a no-op
	// insert keyed by IssueBacklogID).
	e.srv.PostIssueBacklogs(ctx)
	if missing, err := e.st.(store.IssueDiscussions).TenantsMissingIssueBacklog(ctx); err != nil || slices.Contains(missing, tid) {
		t.Fatalf("after a second sweep: %v %v", missing, err)
	}
	st, err := e.st.(store.IssueDiscussions).DiscussionStates(ctx, tid, []string{store.IssueBacklogID(tid)})
	if err != nil || st[store.IssueBacklogID(tid)].State != store.DiscussionLive || st[store.IssueBacklogID(tid)].Channel != store.ChannelLobby {
		t.Fatalf("backlog topic = %v %v, want live in lobby", st, err)
	}
}

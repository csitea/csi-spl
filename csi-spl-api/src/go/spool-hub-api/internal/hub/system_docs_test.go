package hub_test

import (
	"context"
	"fmt"
	"net/http"
	"slices"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 137 T022 and T024 on testkit Postgres (PRE_PUSH_TIER=full): the repo
// docs (the system tenant, rdb 0191) through the doctree routes with
// ?fs=repo, and the 075 repo-edit save refused for a Qto-managed doc.
//
//	go test ./internal/hub -run 'RepoFS|QtoManaged' -v

// sysDoc writes one folder and one document with an item into the system
// tenant, as the operator import does, and returns the doc id and the
// folder name (unique per test: the system tree is shared by the run).
func sysDoc(t *testing.T, e *env, tag string) (string, string) {
	t.Helper()
	pg := e.st.(*store.Postgres)
	ctx := context.Background()
	folder := "repo-" + tag
	if _, err := pg.DocFolderCreate(ctx, store.SystemTenant, store.DocFolder{Name: folder, Actor: "ci"}); err != nil {
		t.Fatal(err)
	}
	doc, root, err := pg.DocCreateIn(ctx, store.SystemTenant, "", "Repo guide "+tag, "", "ci")
	if err != nil {
		t.Fatal(err)
	}
	if _, err := pg.DocItemAdd(ctx, store.SystemTenant, store.DocItemAddReq{DocID: doc, Anchor: root,
		Where: store.DocChild, Title: "Overview", Body: "the repo", Actor: "ci"}); err != nil {
		t.Fatal(err)
	}
	return doc, folder
}

// repoFSReads checks the read routes of fs=repo for one caller: the system
// doc is listed, opened and searched there, and never in the caller's own
// workspace tree.
func repoFSReads(t *testing.T, e *env, tid, as, doc, folder string) {
	t.Helper()
	nodes := mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/nodes?fs=repo", as, nil, 200)
	if !slices.ContainsFunc(dtList(nodes, "nodes"), func(n map[string]any) bool { return dtStr(n, "name") == folder }) {
		t.Errorf("fs=repo nodes miss folder %s: %v", folder, nodes)
	}
	list := mustCall(t, e, tid, http.MethodGet, docTreeAPI+"?fs=repo", as, nil, 200)
	if !strings.Contains(mapIDs(list), doc) {
		t.Errorf("fs=repo list misses %s", doc)
	}
	head := mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/"+doc+"?fs=repo", as, nil, 200)
	if !strings.HasPrefix(dtStr(head, "title"), "Repo guide ") {
		t.Errorf("fs=repo head: %v", head)
	}
	sub := mustCall(t, e, tid, http.MethodGet, docTreeAPI+"/"+doc+"/subtree?fs=repo", as, nil, 200)
	if got := outlines(sub); got != "1 Overview" {
		t.Errorf("fs=repo subtree = %q, want 1 Overview", got)
	}
	// The workspace tree (no fs, and fs=workspace) does not hold it.
	for _, q := range []string{"", "?fs=workspace"} {
		if code, out := call(t, e, tid, http.MethodGet, docTreeAPI+"/"+doc+q, as, nil); code != http.StatusNotFound {
			t.Errorf("GET %s%s in the workspace tree: %d %v, want 404", doc, q, code, out)
		}
		list := mustCall(t, e, tid, http.MethodGet, docTreeAPI+q, as, nil, 200)
		if strings.Contains(mapIDs(list), doc) {
			t.Errorf("the workspace list%s holds the repo doc %s", q, doc)
		}
	}
}

// mapIDs joins the ids of a list answer's docs.
func mapIDs(m map[string]any) string {
	var ids []string
	for _, d := range dtList(m, "docs") {
		ids = append(ids, dtStr(d, "id"))
	}
	return strings.Join(ids, ",")
}

// repoFSWritesRefused: every write route with fs=repo answers 403
// repo_docs_read_only and the system doc is unchanged.
func repoFSWritesRefused(t *testing.T, e *env, tid, as, doc string) {
	t.Helper()
	for _, c := range []struct {
		method, path string
		body         any
	}{
		{http.MethodPost, docTreeAPI + "?fs=repo", map[string]any{"title": "planted"}},
		{http.MethodPost, docTreeAPI + "/folders?fs=repo", map[string]any{"name": "planted"}},
		{http.MethodPatch, docTreeAPI + "/" + doc + "?fs=repo", map[string]any{"title": "planted", "rev": 2}},
		{http.MethodPost, docTreeAPI + "/" + doc + "/items?fs=repo", map[string]any{"rev": 2, "where": "child", "title": "planted"}},
		{http.MethodDelete, docTreeAPI + "/" + doc + "?fs=repo&rev=2", nil},
	} {
		code, out := call(t, e, tid, c.method, c.path, as, c.body)
		if code != http.StatusForbidden || errOf(out) != "repo_docs_read_only" {
			t.Errorf("%s %s: %d %v, want 403 repo_docs_read_only", c.method, c.path, code, out)
		}
	}
	h, err := e.st.(*store.Postgres).DocHeadOf(context.Background(), store.SystemTenant, doc)
	if err != nil || h.Rev != 2 || !strings.HasPrefix(h.Title, "Repo guide ") {
		t.Errorf("the system doc changed: %+v %v", h, err)
	}
}

// TestWorkspaceDocRepoFS: a workspace's members read the repo docs through
// fs=repo (a developer and a read-only tester), never write them, and the
// anonymous visitor and a bad fs are refused.
func TestWorkspaceDocRepoFS(t *testing.T) {
	e, tid, dev := docTreeEnv(t)
	doc, folder := sysDoc(t, e, tid)
	repoFSReads(t, e, tid, dev, doc, folder)
	repoFSReads(t, e, tid, seat(t, e, tid, rbac.Tester), doc, folder)
	repoFSWritesRefused(t, e, tid, dev, doc)
	if code, out := call(t, e, tid, http.MethodGet, docTreeAPI+"/nodes?fs=repo", "", nil); code != http.StatusForbidden {
		t.Errorf("anonymous fs=repo: %d %v, want 403", code, out)
	}
	if code, out := call(t, e, tid, http.MethodGet, docTreeAPI+"/nodes?fs=git", dev, nil); code != http.StatusBadRequest {
		t.Errorf("fs=git: %d %v, want 400", code, out)
	}
	// CONTROL: the workspace tree still takes writes.
	mustCall(t, e, tid, http.MethodPost, docTreeAPI, dev, map[string]any{"title": "own"}, 200)
}

// TestWorkspaceDocRepoFSOperator: the admin of the operator workspace reads
// the repo docs like any member, and the operator workspace (its admin and
// its agents) is the one writer of them (spec 137 T030a, the import's door):
// a create with fs=repo lands in the system tenant, not in the workspace.
// CONTROL: a developer of the operator workspace, the admin and an agent of
// another workspace are refused the same writes, and the doc is unchanged.
func TestWorkspaceDocRepoFSOperator(t *testing.T) {
	e, op, other, who, whoOther := operatorEnv(t, func(op, _ string) string { return op })
	pg, ok := e.st.(*store.Postgres)
	if !ok {
		t.Skip("workspace documents need Postgres (SPOOL_TEST_PG_DSN)")
	}
	doc, folder := sysDoc(t, e, op)
	repoFSReads(t, e, op, who[rbac.Admin], doc, folder)
	repoFSWritesRefused(t, e, op, who[rbac.Developer], doc)
	repoFSWritesRefused(t, e, other, whoOther[rbac.Admin], doc)
	ob := e.box(other, "box-other", "c-002")
	e.pin(other, ob)
	otherAgent := e.uploadToken(other, ob)
	if code, out := opCall(t, e, other, http.MethodPost, docTreeAPI+"?fs=repo", otherAgent, map[string]any{"title": "planted"}); code != http.StatusForbidden || errOf(out) != "repo_docs_read_only" {
		t.Errorf("another workspace's agent: %d %v, want 403 repo_docs_read_only", code, out)
	}

	// The operator workspace's admin writes the repo tree.
	out := mustCall(t, e, op, http.MethodPost, docTreeAPI+"?fs=repo", who[rbac.Admin], map[string]any{"title": "Imported " + op}, 200)
	made := dtStr(out, "id")
	mustCall(t, e, op, http.MethodPost, docTreeAPI+"/"+made+"/items?fs=repo", who[rbac.Admin],
		map[string]any{"rev": 1, "where": "child", "title": "Section"}, 200)
	if h, err := pg.DocHeadOf(context.Background(), store.SystemTenant, made); err != nil || h.Title != "Imported "+op || h.Items != 2 {
		t.Errorf("the admin's fs=repo create is not a system doc: %+v %v", h, err)
	}
	if code, _ := call(t, e, op, http.MethodGet, docTreeAPI+"/"+made, who[rbac.Admin], nil); code != http.StatusNotFound {
		t.Errorf("the fs=repo create is in the operator workspace tree: %d, want 404", code)
	}
	// And so does its agent (the desk box the import runs as).
	b := e.box(op, "box-desk", "c-001")
	e.pin(op, b)
	agent := e.uploadToken(op, b)
	code, out := opCall(t, e, op, http.MethodPost, docTreeAPI+"?fs=repo", agent, map[string]any{"title": "Agent " + op})
	if code != http.StatusOK {
		t.Fatalf("the operator workspace's agent: %d %v, want 200", code, out)
	}
	if _, err := pg.DocHeadOf(context.Background(), store.SystemTenant, dtStr(out, "id")); err != nil {
		t.Errorf("the agent's fs=repo create is not a system doc: %v", err)
	}
	h, err := pg.DocHeadOf(context.Background(), store.SystemTenant, doc)
	if err != nil || h.Rev != 2 || !strings.HasPrefix(h.Title, "Repo guide ") {
		t.Errorf("the refused writes changed the system doc: %+v %v", h, err)
	}
	// The operator workspace list leaves the system tenant out.
	out = mustCall(t, e, op, http.MethodGet, opPath, who[rbac.Admin], nil, 200)
	for _, w := range dtList(out, "workspaces") {
		if dtStr(w, "id") == store.SystemTenant {
			t.Errorf("the operator workspace list holds the system tenant")
		}
	}
}

// stamped is a published doc that is a Qto export (spec 137 section 5.1).
const stamped = "# Runbook\n\n> Generated from qto doc `c02033bc-1c58-419f-88c2-4762810121aa`; edit it there. " +
	"This file is its export: `cd csi-spl-orc && ./run -a do_spl_doctree_export_md` rewrites it.\n\nbody\n"

// TestRepoDocsQtoManaged409: a save of a doc whose published text is a Qto
// export answers 409 qto_managed and writes nothing; a failed edit of a doc
// that became Qto-managed is not retried. CONTROL: the rig's plain doc saves.
func TestRepoDocsQtoManaged409(t *testing.T) {
	r := newRepoRig(t)
	alice := seat(t, r.e, r.tid, rbac.Developer)
	r.consent(alice)
	if code, body := r.save(r.doc, alice, r.blob, "# Guide\n\nline one\nmine\n"); code != http.StatusOK {
		t.Fatalf("control save: %d %v", code, body)
	}

	// Published with a known base, so only the stamp can refuse the save.
	runbook, rbBlob := r.dir+"/runbook.md", strings.Repeat("d", 40)
	r.put(runbook, stamped)
	r.put("tree.json", fmt.Sprintf(`{"v":1,"sha":"%s","files":[{"path":%q,"title":"Guide","blob":%q},{"path":%q,"title":"Runbook","blob":%q}]}`,
		strings.Repeat("c", 40), r.doc, r.blob, runbook, rbBlob))
	code, body := r.save(runbook, alice, rbBlob, "# Runbook\n\nhand edit\n")
	if code != http.StatusConflict || errOf(body) != "qto_managed" ||
		!strings.Contains(body["detail"].(string), "c02033bc-1c58-419f-88c2-4762810121aa") {
		t.Fatalf("save of a Qto export: %d %v, want 409 qto_managed naming the doc", code, body)
	}
	if n, o := len(r.edits(runbook)), r.overlays(runbook); n != 0 || len(o) != 0 {
		t.Fatalf("a 409 qto_managed wrote: %d rows, overlays %v", n, o)
	}

	// The rig's doc turns Qto-managed while its edit sits failed.
	id := r.edits(r.doc)[0].EditID
	r.claim(id)
	if _, err := r.pg.FailRepoDocEdit(context.Background(), id, "github 401", time.Now()); err != nil {
		t.Fatal(err)
	}
	r.put(r.doc, stamped)
	if code, b, _ := r.do(http.MethodPost, "edits/"+id+"/retry", alice, "", ""); code != http.StatusConflict || errOf(b) != "qto_managed" {
		t.Fatalf("retry of an edit of a Qto export: %d %v, want 409 qto_managed", code, b)
	}
}

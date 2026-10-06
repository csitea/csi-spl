package hub_test

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/github"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Editable Repo Docs (spec 075 repo-edit §10 API, task T08): every answer of
// the API table, on Postgres (the edit queue lives only there; on the memory
// store the routes stay off and these tests skip).

// repoDeny is cnf env.docs.repo_edit.deny (spec §5.2).
var repoDeny = []string{"**/CLAUDE.md", "**/GEMINI.md", "**/AGENTS.md", "**/.*", "**/.*/**", "csi-spl-wui/**",
	"csi-spl-api/**", "csi-spl-rdb/**", "csi-spl-cnf/**", "csi-spl-iac/src/terraform/**",
	"csi-spl-orc/src/bash/features/*/assets/**", "**/*.tpl.md", "csi-spl-doc/doc/md/lane-integration-rules.md",
	"csi-spl-doc/doc/help/**", "csi-spl-doc/specs/**/tasks.md", "**/tests/**", "**/fixtures/**", "**/testdata/**",
	"**/*.fixture.md", "**/node_modules/**", "tpl-gen/**", "**/bin/**", "**/secrets/**"}

// fakeRepo is master as the conflict view and the head-base check read it.
type fakeRepo struct {
	head  github.Head
	blobs map[string][]byte
}

func (f *fakeRepo) HeadBlob(context.Context, string) (github.Head, error) { return f.head, nil }
func (f *fakeRepo) Blob(_ context.Context, sha string) ([]byte, error) {
	if b, ok := f.blobs[sha]; ok {
		return b, nil
	}
	return nil, fmt.Errorf("no blob %s", sha)
}

// repoRig is one hub with editing on, a docs bucket dir, and a published
// doc under a path prefix of its own (the overlay read is env-wide, so each
// test edits its own paths).
type repoRig struct {
	t    *testing.T
	e    *env
	pg   *store.Postgres
	root string
	tid  string
	dir  string // the rig's editable dir, holding doc
	doc  string // a published, editable doc
	blob string // doc's published blob sha
	repo *fakeRepo
	re   *hub.RepoEdit
}

func newRepoRig(t *testing.T, mut ...func(*hub.RepoEdit)) *repoRig {
	t.Helper()
	root := t.TempDir()
	rp := &fakeRepo{blobs: map[string][]byte{}}
	re := &hub.RepoEdit{Env: "dev", Deny: repoDeny, CoalesceAfter: 2 * time.Minute, CoalesceMax: 10 * time.Minute,
		RateMemberHour: 30, RateAgentHour: 60, RateWorkspaceDay: 100, Repo: rp}
	for _, m := range mut {
		m(re)
	}
	e := rbacEnv(t, func(o *hub.Options) { o.Docs = blob.Dir{Root: root}; o.RepoEdit = re })
	pg, ok := e.st.(*store.Postgres)
	if !ok {
		t.Skip("repo docs edits need Postgres (SPOOL_TEST_PG_DSN)")
	}
	tid, _ := e.tenant()
	b := make([]byte, 4)
	rand.Read(b) //nolint:errcheck
	r := &repoRig{t: t, e: e, pg: pg, root: root, tid: tid, repo: rp, re: re,
		dir: "csi-spl-doc/rig-" + hex.EncodeToString(b)}
	r.doc = r.dir + "/guide.md"
	r.blob = strings.Repeat("a", 40)
	r.put(r.doc, "# Guide\n\nline one\n")
	r.put("csi-spl-wui/README.md", "# wui\n")
	r.put("tree.json", fmt.Sprintf(`{"v":1,"sha":"%s","files":[{"path":%q,"title":"Guide","blob":%q},{"path":"csi-spl-wui/README.md","title":"wui","blob":"%s"}]}`,
		strings.Repeat("c", 40), r.doc, r.blob, strings.Repeat("b", 40)))
	return r
}

func (r *repoRig) put(p, body string) {
	f := filepath.Join(r.root, filepath.FromSlash(p))
	if err := os.MkdirAll(filepath.Dir(f), 0o755); err != nil {
		r.t.Fatal(err)
	}
	if err := os.WriteFile(f, []byte(body), 0o644); err != nil {
		r.t.Fatal(err)
	}
}

// do calls a /v1/docs route as a member (as) or with an agent bearer.
func (r *repoRig) do(method, path, as, bearer, body string, hdr ...string) (int, map[string]any, http.Header) {
	r.t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, _ := http.NewRequest(method, r.e.url(r.tid)+"/v1/docs/"+path, rd)
	if as != "" {
		req.Header.Set(memberHeader, as)
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	for i := 0; i+1 < len(hdr); i += 2 {
		req.Header.Set(hdr[i], hdr[i+1])
	}
	resp, err := r.e.client.Do(req)
	if err != nil {
		r.t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	out := map[string]any{}
	if json.Unmarshal(raw, &out) != nil {
		out["raw"] = string(raw)
	}
	return resp.StatusCode, out, resp.Header
}

// save PUTs text to p as `as`, against base.
func (r *repoRig) save(p, as, base, text string, hdr ...string) (int, map[string]any) {
	r.t.Helper()
	if base != "" {
		hdr = append(hdr, "If-Match", `"`+base+`"`)
	}
	code, body, _ := r.do(http.MethodPut, p, as, "", text, hdr...)
	return code, body
}

// consent acks the author notice for as (the identity the 428 named).
func (r *repoRig) consent(as string) {
	r.t.Helper()
	code, body := r.save(r.doc, as, r.blob, "# Guide\n\nline one\nprobe\n")
	if code != http.StatusPreconditionRequired {
		r.t.Fatalf("first save, want 428: %d %v", code, body)
	}
	in, _ := json.Marshal(map[string]any{"git_name": body["git_name"], "git_email": body["git_email"]})
	if code, b, _ := r.do(http.MethodPost, "author-notice", as, "", string(in)); code != http.StatusNoContent {
		r.t.Fatalf("author notice: %d %v", code, b)
	}
}

func (r *repoRig) edits(p string) []store.RepoDocEdit {
	r.t.Helper()
	rows, err := r.pg.ListRepoDocEdits(context.Background(), r.tid, store.RepoDocEditFilter{Path: p})
	if err != nil {
		r.t.Fatal(err)
	}
	return rows
}

func (r *repoRig) overlays(p string) []string {
	var keys []string
	blob.Dir{Root: r.root}.List(context.Background(), ".edits/"+p+"/", func(k string, _ time.Time) error { //nolint:errcheck
		keys = append(keys, k)
		return nil
	})
	return keys
}

func (r *repoRig) getDoc(p, as string) (int, string, http.Header) {
	r.t.Helper()
	return getDoc(r.t, r.e, r.tid, p, as)
}

func errOf(b map[string]any) string { s, _ := b["error"].(string); return s }

func TestRepoDocsEditOffEveryWriteRoute404(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "tree.json"), []byte(`{"files":[]}`), 0o644) //nolint:errcheck
	e := rbacEnv(t, func(o *hub.Options) { o.Docs = blob.Dir{Root: root} })       // RepoEdit nil: enabled false
	tid, _ := e.tenant()
	hum := seat(t, e, tid, rbac.Developer)
	r := &repoRig{t: t, e: e, tid: tid}
	id := "6f1c1a52-0000-4000-8000-000000000001"
	for _, c := range []struct{ method, path string }{
		{http.MethodPut, "csi-spl-doc/x.md"}, {http.MethodPost, "author-notice"}, {http.MethodGet, "edits?mine=1"},
		{http.MethodPost, "edits/" + id + "/retry"}, {http.MethodGet, "edits/" + id + "/conflict"},
	} {
		if code, body, _ := r.do(c.method, c.path, hum, "", "{}"); code != http.StatusNotFound || errOf(body) != "repo_edit_off" {
			t.Errorf("%s %s with editing off: %d %v, want 404 repo_edit_off", c.method, c.path, code, body)
		}
	}
	if code, body, _ := getDoc(t, e, tid, "tree.json", hum); code != http.StatusOK || body != `{"files":[]}` {
		t.Fatalf("the read route still serves the bucket as is: %d %q", code, body)
	}
}

func TestRepoDocsSaveNoticeThenQueuedAndServed(t *testing.T) {
	r := newRepoRig(t)
	alice, bob := seat(t, r.e, r.tid, rbac.Developer), seat(t, r.e, r.tid, rbac.Tester)

	code, body := r.save(r.doc, alice, r.blob, "# Guide\n\nline one\nline two\n")
	if code != http.StatusPreconditionRequired || errOf(body) != "author_notice_required" ||
		body["author_source"] != "signin" || !strings.HasSuffix(fmt.Sprint(body["git_email"]), "@example.com") {
		t.Fatalf("no consent: %d %v, want 428 with the identity", code, body)
	}
	if n, o := len(r.edits(r.doc)), r.overlays(r.doc); n != 0 || len(o) != 0 {
		t.Fatalf("a 428 wrote: %d rows, overlays %v", n, o)
	}
	// a consent to another identity than the one published is refused
	if code, b, _ := r.do(http.MethodPost, "author-notice", alice, "", `{"git_name":"Someone","git_email":"x@example.com"}`); code != http.StatusConflict || errOf(b) != "author_changed" {
		t.Fatalf("consent to another identity: %d %v", code, b)
	}
	in, _ := json.Marshal(map[string]any{"git_name": body["git_name"], "git_email": body["git_email"]})
	if code, b, _ := r.do(http.MethodPost, "author-notice", alice, "", string(in)); code != http.StatusNoContent {
		t.Fatalf("consent: %d %v", code, b)
	}
	code, body = r.save(r.doc, alice, r.blob, "# Guide\n\nline one\nline two\n")
	if code != http.StatusOK || body["status"] != "queued" || body["edit_id"] == "" {
		t.Fatalf("save after consent: %d %v", code, body)
	}
	id := body["edit_id"].(string)
	rows := r.edits(r.doc)
	if len(rows) != 1 || rows[0].EditID != id || rows[0].HumanID != alice || rows[0].ActorKind != "member" ||
		rows[0].BaseBlob != r.blob || rows[0].OverlayKey != ".edits/"+r.doc+"/"+id+".md" {
		t.Fatalf("row: %+v", rows)
	}
	// every member reads the newest saved text, with its base and edit
	code, text, h := r.getDoc(r.doc, bob)
	if code != http.StatusOK || text != "# Guide\n\nline one\nline two\n" || h.Get("X-Spool-Doc-Edit") != id || h.Get("X-Spool-Doc-Base") != r.blob {
		t.Fatalf("overlay read: %d %q %v", code, text, h)
	}
	// tree.json: the editable flag per file, the overlay marked
	code, raw, _ := r.getDoc("tree.json", bob)
	var tree struct {
		SHA   string           `json:"sha"`
		Files []map[string]any `json:"files"`
	}
	if code != http.StatusOK || json.Unmarshal([]byte(raw), &tree) != nil || tree.SHA != strings.Repeat("c", 40) {
		t.Fatalf("tree: %d %s", code, raw)
	}
	for _, f := range tree.Files {
		switch f["path"] {
		case r.doc:
			if f["editable"] != true || f["overlay"] != true || f["blob"] != r.blob {
				t.Errorf("doc entry: %v", f)
			}
		case "csi-spl-wui/README.md":
			if f["editable"] != false || f["overlay"] != nil {
				t.Errorf("denied entry: %v", f)
			}
		}
	}
	// a second save of the same author folds into the first (coalescing)
	code, body = r.save(r.doc, alice, r.blob, "# Guide\n\nline one\nline two\nline three\n")
	if code != http.StatusOK || fmt.Sprint(body["superseded"]) != "["+id+"]" {
		t.Fatalf("second save: %d %v", code, body)
	}
	// My edits
	code, list, _ := r.do(http.MethodGet, "edits?mine=1", alice, "", "")
	if es, _ := list["edits"].([]any); code != http.StatusOK || len(es) != 2 ||
		es[0].(map[string]any)["status"] != "queued" || es[1].(map[string]any)["status"] != "superseded" {
		t.Fatalf("my edits: %d %v", code, list)
	}
	if code, list, _ = r.do(http.MethodGet, "edits?mine=1", bob, "", ""); code != http.StatusOK || len(list["edits"].([]any)) != 0 {
		t.Fatalf("bob's edits: %d %v", code, list)
	}
	if code, list, _ = r.do(http.MethodGet, "edits", alice, "", ""); code != http.StatusBadRequest {
		t.Fatalf("edits without a filter: %d %v", code, list)
	}
}

func TestRepoDocsSaveRefusals(t *testing.T) {
	r := newRepoRig(t)
	alice := seat(t, r.e, r.tid, rbac.Developer)
	r.consent(alice)
	before := len(r.edits(r.doc))
	refused := func(name string, want int, reason string, code int, body map[string]any) {
		t.Helper()
		if code != want || (reason != "" && errOf(body) != reason) {
			t.Errorf("%s: %d %v, want %d %s", name, code, body, want, reason)
		}
	}
	code, body := r.save("csi-spl-wui/README.md", alice, strings.Repeat("b", 40), "# x\n")
	refused("denied path", http.StatusForbidden, "path_denied", code, body)
	code, body = r.save("nowhere/new.md", alice, "", "# x\n")
	refused("not published, no editable dir", http.StatusForbidden, "path_denied", code, body)
	code, body = r.save(r.doc, alice, strings.Repeat("9", 40), "# x\n")
	refused("unknown base", http.StatusConflict, "base_unknown", code, body)
	code, body = r.save(r.doc, alice, "", "# x\n")
	refused("no If-Match on a published doc", http.StatusConflict, "base_unknown", code, body)
	code, body = r.save(r.doc, alice, r.blob, strings.Repeat("x", hub.MaxRepoDoc+1))
	refused("too large", http.StatusRequestEntityTooLarge, "too_large", code, body)
	code, body = r.save(r.doc, alice, r.blob, "# Guide\n\nline one\n-----BEGIN RSA PRIVATE KEY-----\n")
	refused("secret", http.StatusUnprocessableEntity, "rejected_text", code, body)
	if hits, _ := body["hits"].([]any); len(hits) == 0 || strings.Contains(fmt.Sprint(body), "BEGIN RSA") {
		t.Errorf("rejected text names the rule and line: %v", body)
	}
	if after := len(r.edits(r.doc)); after != before {
		t.Fatalf("a refusal wrote a row: %d -> %d", before, after)
	}
	// a NEW file in an editable dir: no base
	if code, body = r.save(r.dir+"/new.md", alice, "", "# New\n"); code != http.StatusOK {
		t.Fatalf("new file in an editable dir: %d %v", code, body)
	}
	if _, raw, _ := r.getDoc("tree.json", alice); !strings.Contains(raw, `"path":"`+r.dir+`/new.md"`) {
		t.Fatalf("tree.json lacks the overlay-only path: %s", raw)
	}
	if code, text, h := r.getDoc(r.dir+"/new.md", alice); code != http.StatusOK || text != "# New\n" || h.Get("X-Spool-Doc-Base") != "" {
		t.Fatalf("new doc read: %d %q", code, text)
	}
}

func TestRepoDocsWorkspaceBlockedMemberAgeAndUnverified(t *testing.T) {
	r := newRepoRig(t, func(re *hub.RepoEdit) { re.MinMemberAge = time.Hour })
	alice := seat(t, r.e, r.tid, rbac.Developer)
	if code, body := r.save(r.doc, alice, r.blob, "# x\n"); code != http.StatusForbidden || errOf(body) != "member_too_new" {
		t.Fatalf("a member of 0s: %d %v", code, body)
	}

	r = newRepoRig(t)
	r.re.BlockedWorkspaces = []string{r.tid}
	alice = seat(t, r.e, r.tid, rbac.Developer)
	if code, body := r.save(r.doc, alice, r.blob, "# x\n"); code != http.StatusForbidden || errOf(body) != "workspace_blocked" {
		t.Fatalf("blocked workspace: %d %v", code, body)
	}

	// a member whose sign-in carries no verified email never publishes one
	r = newRepoRig(t)
	t2, _ := r.e.tenant()
	r.tid = t2
	nomail, err := r.e.st.(store.Humans).Admit(context.Background(), store.Identity{Provider: "google", Subject: "s-nomail-" + t2},
		t2, store.AdmitPolicy{BootstrapOwner: true}, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	if code, body := r.save(r.doc, nomail, r.blob, "# x\n"); code != http.StatusForbidden || errOf(body) != "email_unverified" {
		t.Fatalf("unverified: %d %v", code, body)
	}
}

func TestRepoDocsDemoUserForbidden(t *testing.T) {
	root := t.TempDir()
	os.WriteFile(filepath.Join(root, "tree.json"), []byte(`{"files":[{"path":"csi-spl-doc/d.md","blob":"`+strings.Repeat("a", 40)+`"}]}`), 0o644) //nolint:errcheck
	e, demo := demoEnv(t, func(o *hub.Options) {
		o.Docs = blob.Dir{Root: root}
		o.RepoEdit = &hub.RepoEdit{Env: "dev", Deny: repoDeny}
	})
	if _, ok := e.st.(*store.Postgres); !ok {
		t.Skip("repo docs edits need Postgres (SPOOL_TEST_PG_DSN)")
	}
	visitor := seat(t, e, demo, rbac.DemoUser)
	r := &repoRig{t: t, e: e, tid: demo}
	if code, body := r.save("csi-spl-doc/d.md", visitor, strings.Repeat("a", 40), "# x\n"); code != http.StatusForbidden {
		t.Fatalf("demo_user save: %d %v, want 403", code, body)
	}
}

func TestRepoDocsRateLimits(t *testing.T) {
	r := newRepoRig(t, func(re *hub.RepoEdit) { re.RateMemberHour = 2 })
	alice := seat(t, r.e, r.tid, rbac.Developer)
	r.consent(alice) // the probe is refused with 428: no row, no count
	for i := 0; i < 2; i++ {
		if code, body := r.save(r.doc, alice, r.blob, fmt.Sprintf("# Guide\n\nline one\n%d\n", i)); code != http.StatusOK {
			t.Fatalf("save %d: %d %v", i, code, body)
		}
	}
	if code, body := r.save(r.doc, alice, r.blob, "# Guide\n\nline one\nthird\n"); code != http.StatusTooManyRequests || errOf(body) != "rate_limited" {
		t.Fatalf("third save in the hour: %d %v", code, body)
	}

	r = newRepoRig(t, func(re *hub.RepoEdit) { re.RateWorkspaceDay = 1 })
	alice, bob := seat(t, r.e, r.tid, rbac.Developer), seat(t, r.e, r.tid, rbac.Developer)
	r.consent(alice)
	r.consent(bob)
	if code, body := r.save(r.doc, alice, r.blob, "# Guide\n\nline one\na\n"); code != http.StatusOK {
		t.Fatalf("first: %d %v", code, body)
	}
	if code, body := r.save(r.doc, bob, r.blob, "# Guide\n\nline one\nb\n"); code != http.StatusTooManyRequests {
		t.Fatalf("workspace cap: %d %v", code, body)
	}

	// the env cap counts every workspace: at the current count, nothing more lands
	r = newRepoRig(t)
	carol := seat(t, r.e, r.tid, rbac.Developer)
	r.consent(carol)
	if code, body := r.save(r.doc, carol, r.blob, "# Guide\n\nline one\nfirst\n"); code != http.StatusOK {
		t.Fatalf("under the env cap: %d %v", code, body)
	}
	n, err := r.pg.RepoDocEditsEnvDay(context.Background(), time.Now().Add(-24*time.Hour))
	if err != nil || n < 1 {
		t.Fatalf("env day count: %d %v", n, err)
	}
	r.re.RateEnvDay = n
	if code, body := r.save(r.doc, carol, r.blob, "# Guide\n\nline one\nc\n"); code != http.StatusTooManyRequests ||
		!strings.Contains(fmt.Sprint(body["detail"]), "env") {
		t.Fatalf("env cap: %d %v", code, body)
	}
}

func TestRepoDocsAgentForItsRequester(t *testing.T) {
	r := newRepoRig(t)
	alice, outsider := seat(t, r.e, r.tid, rbac.Developer), "HUM-999999999"
	b := r.e.box(r.tid, "box-ed", "GRK-04")
	r.e.pin(r.tid, b)
	tok := r.e.uploadToken(r.tid, b)
	agentSave := func(requester string) (int, map[string]any) {
		h := []string{"If-Match", r.blob}
		if requester != "" {
			h = append(h, hub.RequesterHeader, requester)
		}
		code, body, _ := r.do(http.MethodPut, r.doc, "", tok, "# Guide\n\nline one\nby agent\n", h...)
		return code, body
	}
	if code, body := agentSave(""); code != http.StatusForbidden || errOf(body) != "requester_required" {
		t.Fatalf("no requester: %d %v", code, body)
	}
	if code, body := agentSave(outsider); code != http.StatusForbidden || errOf(body) != "requester_invalid" {
		t.Fatalf("not a member: %d %v", code, body)
	}
	if code, body := agentSave(alice); code != http.StatusPreconditionRequired || !strings.Contains(fmt.Sprint(body["detail"]), "requester") {
		t.Fatalf("requester without consent: %d %v", code, body)
	}
	r.consent(alice)
	code, body := agentSave(alice)
	if code != http.StatusOK {
		t.Fatalf("agent for its requester: %d %v", code, body)
	}
	row, err := r.pg.GetRepoDocEdit(context.Background(), r.tid, body["edit_id"].(string))
	if err != nil || row.ActorKind != "agent" || row.AgentID != "box-ed" || row.HumanID != alice ||
		!strings.HasSuffix(row.AuthorEmail, "@example.com") {
		t.Fatalf("agent row: %+v %v", row, err)
	}
	// the requester sees it in My edits; agents use no session routes
	code, list, _ := r.do(http.MethodGet, "edits?mine=1", alice, "", "")
	if es, _ := list["edits"].([]any); code != http.StatusOK || len(es) != 1 || es[0].(map[string]any)["agent_id"] != "box-ed" {
		t.Fatalf("requester's edits: %d %v", code, list)
	}
	if code, _, _ := r.do(http.MethodGet, "edits?mine=1", "", tok, ""); code != http.StatusForbidden {
		t.Fatalf("agent on a member-only route: %d", code)
	}
	if code, _, _ := r.do(http.MethodPost, "author-notice", "", tok, `{"git_name":"a","git_email":"a@example.com"}`); code != http.StatusForbidden {
		t.Fatalf("agent gives consent: %d", code)
	}
	// agent edits off for the requester
	if err := r.pg.PutRepoDocAuthor(context.Background(), store.RepoDocAuthor{TenantID: r.tid, HumanID: alice, AllowAgents: false}); err != nil {
		t.Fatal(err)
	}
	if code, body := agentSave(alice); code != http.StatusForbidden || errOf(body) != "requester_invalid" {
		t.Fatalf("agents off: %d %v", code, body)
	}
}

// claim takes every due queued row of the queue (the worker's claim), far
// in the future so the coalescing window is over.
func (r *repoRig) claim(id string) {
	r.t.Helper()
	rows, err := r.pg.ClaimRepoDocEdits(context.Background(), 1000, time.Now().Add(time.Hour))
	if err != nil {
		r.t.Fatal(err)
	}
	for _, e := range rows {
		if e.EditID == id {
			return
		}
	}
	r.t.Fatalf("edit %s was not claimed", id)
}

func TestRepoDocsRetryAndConflict(t *testing.T) {
	r := newRepoRig(t)
	alice, bob := seat(t, r.e, r.tid, rbac.Developer), seat(t, r.e, r.tid, rbac.Developer)
	admin := seat(t, r.e, r.tid, rbac.Admin)
	r.consent(alice)
	ctx := context.Background()

	_, body := r.save(r.doc, alice, r.blob, "# Guide\n\nline one\nmine\n")
	id := body["edit_id"].(string)
	if code, b, _ := r.do(http.MethodPost, "edits/"+id+"/retry", alice, "", ""); code != http.StatusConflict || errOf(b) != "not_failed" {
		t.Fatalf("retry a queued edit: %d %v", code, b)
	}
	r.claim(id)
	if _, err := r.pg.FailRepoDocEdit(ctx, id, "github 401", time.Now()); err != nil {
		t.Fatal(err)
	}
	if code, _, _ := r.do(http.MethodPost, "edits/"+id+"/retry", bob, "", ""); code != http.StatusForbidden {
		t.Fatalf("another member retries: %d", code)
	}
	if code, b, _ := r.do(http.MethodPost, "edits/"+id+"/retry", alice, "", ""); code != http.StatusAccepted || b["status"] != "queued" {
		t.Fatalf("editor retries: %d %v", code, b)
	}
	r.claim(id)
	if _, err := r.pg.FailRepoDocEdit(ctx, id, "github 401", time.Now()); err != nil {
		t.Fatal(err)
	}
	if code, _, _ := r.do(http.MethodPost, "edits/"+id+"/retry", admin, "", ""); code != http.StatusAccepted {
		t.Fatalf("admin retries: %d", code)
	}
	if code, _, _ := r.do(http.MethodPost, "edits/not-a-uuid/retry", alice, "", ""); code != http.StatusNotFound {
		t.Fatalf("bad id: %d", code)
	}

	// conflict: the three texts, to the editor only; the overlay serves only them
	r.claim(id)
	if _, err := r.pg.ConflictRepoDocEdit(ctx, id, "master changed the same lines at 1234567", time.Now()); err != nil {
		t.Fatal(err)
	}
	head := strings.Repeat("d", 40)
	r.repo.head = github.Head{Commit: strings.Repeat("e", 40), Blob: head}
	r.repo.blobs[r.blob] = []byte("# Guide\n\nline one\n")
	r.repo.blobs[head] = []byte("# Guide\n\nline one\ntheirs\n")
	code, c, _ := r.do(http.MethodGet, "edits/"+id+"/conflict", alice, "", "")
	if code != http.StatusOK || c["base"] != "# Guide\n\nline one\n" || c["theirs"] != "# Guide\n\nline one\ntheirs\n" ||
		c["mine"] != "# Guide\n\nline one\nmine\n" || c["head_blob"] != head {
		t.Fatalf("conflict view: %d %v", code, c)
	}
	if code, _, _ := r.do(http.MethodGet, "edits/"+id+"/conflict", bob, "", ""); code != http.StatusForbidden {
		t.Fatalf("another member reads the conflict: %d", code)
	}
	if _, text, _ := r.getDoc(r.doc, alice); text != "# Guide\n\nline one\nmine\n" {
		t.Fatalf("the editor reads their conflict text: %q", text)
	}
	if _, text, _ := r.getDoc(r.doc, bob); text != "# Guide\n\nline one\n" {
		t.Fatalf("others read the published text past a conflict: %q", text)
	}
	// the resolution saves against head and supersedes the conflict row
	code, body = r.save(r.doc, alice, head, "# Guide\n\nline one\ntheirs\nmine\n")
	if code != http.StatusOK || fmt.Sprint(body["superseded"]) != "["+id+"]" {
		t.Fatalf("resolution save: %d %v", code, body)
	}
	if row, _ := r.pg.GetRepoDocEdit(ctx, r.tid, id); row.Status != store.RepoDocSuperseded {
		t.Fatalf("conflict row after the resolution: %s", row.Status)
	}
	if code, b, _ := r.do(http.MethodGet, "edits/"+body["edit_id"].(string)+"/conflict", alice, "", ""); code != http.StatusConflict || errOf(b) != "not_conflict" {
		t.Fatalf("conflict view of a queued edit: %d %v", code, b)
	}
}

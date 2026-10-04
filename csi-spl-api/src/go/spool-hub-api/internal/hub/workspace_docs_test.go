package hub_test

import (
	"bytes"
	"context"
	"encoding/json"
	"io"
	"net/http"
	"path/filepath"
	"sort"
	"strings"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/blob"
	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// specs/075 Phase 2 (T007 + T008): each workspace's docs live in its own
// store, resolved from the caller's verified tenant; members and agents
// write, the last save wins, and every write leaves a .history/ record.

// wsDocs is a resolver over one local root: <root>/<tenant>/.
func wsDocs(t *testing.T, root string) *hub.WorkspaceDocs {
	t.Helper()
	d, err := hub.NewWorkspaceDocs(filepath.Join(root, "{tenant}"), func(_ context.Context, dir string) (blob.Store, error) {
		return blob.Dir{Root: dir}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	return d
}

// wsDoc calls /v1/workspace/docs/<path> as a member (as) or with a bearer.
func wsDoc(t *testing.T, e *env, tid, method, path, as, bearer, body string) (int, string) {
	t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, _ := http.NewRequest(method, e.url(tid)+"/v1/workspace/docs/"+path, rd)
	if as != "" {
		req.Header.Set(memberHeader, as)
	}
	if bearer != "" {
		req.Header.Set("Authorization", "Bearer "+bearer)
	}
	resp, err := e.client.Do(req)
	if err != nil {
		t.Fatalf("%s %s: %v", method, path, err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	return resp.StatusCode, string(b)
}

// history is the .history/ records of path in tenant's store, sorted.
func history(t *testing.T, d *hub.WorkspaceDocs, tid, path string) []string {
	t.Helper()
	st, err := d.Store(context.Background(), tid)
	if err != nil {
		t.Fatal(err)
	}
	var keys []string
	st.List(context.Background(), hub.WorkspaceDocsHistory+path+"/", func(k string, _ time.Time) error { //nolint:errcheck
		keys = append(keys, k)
		return nil
	})
	sort.Strings(keys)
	return keys
}

func readKey(t *testing.T, d *hub.WorkspaceDocs, tid, key string) string {
	t.Helper()
	st, _ := d.Store(context.Background(), tid)
	rc, err := st.Get(context.Background(), key)
	if err != nil {
		t.Fatalf("%s: %v", key, err)
	}
	defer rc.Close()
	b, _ := io.ReadAll(rc)
	return string(b)
}

func TestWorkspaceDocsLastWriteWinsWithHistory(t *testing.T) {
	d := wsDocs(t, t.TempDir())
	e := rbacEnv(t, func(o *hub.Options) { o.WorkspaceDocs = d })
	tid, _ := e.tenant()
	alice, bob := seat(t, e, tid, rbac.Tester), seat(t, e, tid, rbac.Developer)

	if code, body := wsDoc(t, e, tid, http.MethodPut, "runbooks/deploy.md", alice, "", "# v1\n"); code != http.StatusOK {
		t.Fatalf("create: %d %s", code, body)
	}
	if code, body := wsDoc(t, e, tid, http.MethodPut, "runbooks/deploy.md", bob, "", "# v2\n"); code != http.StatusOK {
		t.Fatalf("overwrite: %d %s", code, body)
	}
	if code, body := wsDoc(t, e, tid, http.MethodGet, "runbooks/deploy.md", alice, "", ""); code != http.StatusOK || body != "# v2\n" {
		t.Fatalf("read after the last save: %d %q", code, body)
	}
	code, body := wsDoc(t, e, tid, http.MethodGet, "tree.json", alice, "", "")
	var tree hub.WorkspaceDocsTree
	if code != http.StatusOK || json.Unmarshal([]byte(body), &tree) != nil || len(tree.Files) != 1 || tree.Files[0].Path != "runbooks/deploy.md" {
		t.Fatalf("tree (no .history/ in it): %d %s", code, body)
	}
	h := history(t, d, tid, "runbooks/deploy.md")
	if len(h) != 2 || !strings.Contains(h[0], "--"+alice+"--put") || !strings.Contains(h[1], "--"+bob+"--put") ||
		readKey(t, d, tid, h[0]) != "# v1\n" || readKey(t, d, tid, h[1]) != "# v2\n" {
		t.Fatalf("history keeps every version with its author: %v", h)
	}
	if code, body := wsDoc(t, e, tid, http.MethodDelete, "runbooks/deploy.md", alice, "", ""); code != http.StatusOK {
		t.Fatalf("delete: %d %s", code, body)
	}
	if code, _ := wsDoc(t, e, tid, http.MethodGet, "runbooks/deploy.md", alice, "", ""); code != http.StatusNotFound {
		t.Fatalf("deleted doc: %d", code)
	}
	if h = history(t, d, tid, "runbooks/deploy.md"); len(h) != 3 || !strings.Contains(h[2], "--del") || readKey(t, d, tid, h[2]) != "# v2\n" {
		t.Fatalf("delete keeps the deleted bytes: %v", h)
	}
	if code, _ := wsDoc(t, e, tid, http.MethodDelete, "runbooks/deploy.md", alice, "", ""); code != http.StatusNotFound {
		t.Fatalf("delete of a missing doc: %d", code)
	}
}

func TestWorkspaceDocsAgentTokenWrites(t *testing.T) {
	d := wsDocs(t, t.TempDir())
	e := rbacEnv(t, func(o *hub.Options) { o.WorkspaceDocs = d })
	tid, _ := e.tenant()
	b := e.box(tid, "box-a", "GRK-03")
	e.pin(tid, b)
	tok := e.uploadToken(tid, b)
	if code, body := wsDoc(t, e, tid, http.MethodPut, "ops/guide.md", "", tok, "# by an agent\n"); code != http.StatusOK {
		t.Fatalf("agent PUT: %d %s", code, body)
	}
	if code, body := wsDoc(t, e, tid, http.MethodGet, "ops/guide.md", "", tok, ""); code != http.StatusOK || body != "# by an agent\n" {
		t.Fatalf("agent GET: %d %q", code, body)
	}
	if h := history(t, d, tid, "ops/guide.md"); len(h) != 1 || !strings.Contains(h[0], "--box-a--put") {
		t.Fatalf("agent attribution: %v", h)
	}
	// CONTROLS: no session and no token, or a token the hub never minted
	for _, bearer := range []string{"", "not-a-token"} {
		if code, _ := wsDoc(t, e, tid, http.MethodPut, "ops/guide.md", "", bearer, "x"); code != http.StatusUnauthorized && code != http.StatusForbidden {
			t.Fatalf("bearer %q PUT: %d, want 401/403", bearer, code)
		}
	}
	if code, _ := wsDoc(t, e, tid, http.MethodGet, "tree.json", "", "", ""); code == http.StatusOK {
		t.Fatalf("no caller read the tree: %d", code)
	}
}

// T007: the store comes from the caller's verified tenant only.
func TestWorkspaceDocsTenantIsolation(t *testing.T) {
	d := wsDocs(t, t.TempDir())
	e := rbacEnv(t, func(o *hub.Options) { o.WorkspaceDocs = d })
	t1, _ := e.tenant()
	t2, _ := e.tenant()
	m1, m2 := seat(t, e, t1, rbac.Developer), seat(t, e, t2, rbac.Developer)
	if code, body := wsDoc(t, e, t1, http.MethodPut, "secret.md", m1, "", "t1 only\n"); code != http.StatusOK {
		t.Fatalf("t1 write: %d %s", code, body)
	}
	// t2's member on t2: its own store, which has no secret.md
	if code, _ := wsDoc(t, e, t2, http.MethodGet, "secret.md", m2, "", ""); code != http.StatusNotFound {
		t.Fatalf("t2 reads t1's doc through its own host: %d", code)
	}
	// t2's member on t1's host: not a member there
	for _, m := range []string{http.MethodGet, http.MethodPut, http.MethodDelete} {
		if code, _ := wsDoc(t, e, t1, m, "secret.md", m2, "", "overwrite"); code != http.StatusForbidden {
			t.Fatalf("t2 member %s on t1: %d, want 403", m, code)
		}
	}
	// a t2 agent's token on t1's host
	z := e.box(t2, "box-z", "GRK-09")
	e.pin(t2, z)
	tok := e.uploadToken(t2, z)
	if code, _ := wsDoc(t, e, t1, http.MethodPut, "secret.md", "", tok, "overwrite"); code == http.StatusOK {
		t.Fatalf("t2 agent wrote on t1: %d", code)
	}
	if got := readKey(t, d, t1, "secret.md"); got != "t1 only\n" {
		t.Fatalf("t1's doc changed: %q", got)
	}
	l1, _ := d.Location(t1)
	l2, _ := d.Location(t2)
	if l1 == l2 || !strings.HasSuffix(l1, t1) {
		t.Fatalf("locations %q %q", l1, l2)
	}
}

func TestWorkspaceDocsPathsAndSize(t *testing.T) {
	d := wsDocs(t, t.TempDir())
	e := rbacEnv(t, func(o *hub.Options) { o.WorkspaceDocs = d })
	tid, _ := e.tenant()
	hum := seat(t, e, tid, rbac.Tester)
	for _, p := range []string{"tree.json", ".history/a.md/x.md", "a/../b.md", "notes.txt", "a//b.md"} {
		if code, _ := wsDoc(t, e, tid, http.MethodPut, p, hum, "", "x"); code == http.StatusOK {
			t.Fatalf("PUT %s: %d", p, code)
		}
	}
	big := string(bytes.Repeat([]byte("a"), hub.MaxWorkspaceDoc+1))
	if code, _ := wsDoc(t, e, tid, http.MethodPut, "big.md", hum, "", big); code != http.StatusRequestEntityTooLarge {
		t.Fatalf("oversize: %d, want 413", code)
	}
	if code, body := wsDoc(t, e, tid, http.MethodGet, "tree.json", hum, "", ""); code != http.StatusOK || !strings.Contains(body, `"files":[]`) {
		t.Fatalf("nothing landed: %d %s", code, body)
	}
}

func TestWorkspaceDocsOffWithoutStore(t *testing.T) {
	e := rbacEnv(t)
	tid, _ := e.tenant()
	hum := seat(t, e, tid, rbac.Tester)
	for _, m := range []string{http.MethodGet, http.MethodPut, http.MethodDelete} {
		if code, body := wsDoc(t, e, tid, m, "a.md", hum, "", "x"); code != http.StatusNotFound || !strings.Contains(body, "workspace_docs_off") {
			t.Fatalf("%s off: %d %q", m, code, body)
		}
	}
}

func TestNewWorkspaceDocsNeedsTenant(t *testing.T) {
	open := func(context.Context, string) (blob.Store, error) { return blob.Dir{Root: t.TempDir()}, nil }
	if _, err := hub.NewWorkspaceDocs("csi-spl-dev-docs", open); err == nil {
		t.Fatal("a pattern without {tenant} shares one store across workspaces")
	}
	d, err := hub.NewWorkspaceDocs("csi-spl-dev-docs-{tenant}", open)
	if err != nil {
		t.Fatal(err)
	}
	if l, err := d.Location("t1"); err != nil || l != "csi-spl-dev-docs-t1" {
		t.Fatalf("location: %q %v", l, err)
	}
	for _, bad := range []string{"", "../t1", "T1", "a.b"} {
		if _, err := d.Store(context.Background(), bad); err == nil {
			t.Fatalf("tenant %q resolved", bad)
		}
	}
}

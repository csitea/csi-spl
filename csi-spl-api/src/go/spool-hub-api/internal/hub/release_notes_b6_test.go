package hub_test

import (
	"context"
	"net/http"
	"slices"
	"strings"
	"testing"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/store"
)

// Spec 143 releases-projects.md row B-6 (SPL-5801): the operator's repo
// route, the per-repo push through buildRows, and the trailer-free state
// skip with its body. Test: two repos of one workspace, each pushed with its
// own tags, keep their versions apart. RED CONTROL: a row stored around
// buildRows keeps a banned word (TestReleaseNotesEveryRowFiltered fails).

// storedNote reads one stored row of tenant by its sha, any repo.
func storedNote(t *testing.T, e *env, tenant, repo, sha string) store.ReleaseNote {
	t.Helper()
	n, err := e.st.(store.ReleaseNotes).ReleaseNote(context.Background(), tenant, repo, sha)
	if err != nil {
		t.Fatalf("note %s of %s/%s: %v", sha[:8], tenant, repo, err)
	}
	return n
}

// putRepo is PUT /v1/operator/workspaces/{tenant}/repos with the operator token.
func putRepo(t *testing.T, e *env, tenant string, body map[string]any) (int, map[string]any) {
	t.Helper()
	return opCall(t, e, tenant, http.MethodPut, "/v1/operator/workspaces/"+tenant+"/repos", "good", body)
}

func putProject(t *testing.T, e *env, tenant, project string) {
	t.Helper()
	if code, out := opCall(t, e, tenant, http.MethodPut, "/v1/operator/workspaces/"+tenant+"/projects/"+project, "good",
		map[string]any{"name": project}); code != http.StatusOK {
		t.Fatalf("put project %s: %d %v", project, code, out)
	}
}

// The repo route: the first repo is the primary, is_primary moves it, a
// re-put of the primary with false keeps it; each refusal; a member session
// is not an operator.
func TestOperatorRepoPut(t *testing.T) {
	e, tid, hum := releaseEnv(t)
	ws, _ := e.tenant()
	putProject(t, e, ws, "web-shop")
	a, b := repoOf(ws, "api"), repoOf(ws, "wui")
	body := func(repo string, primary bool) map[string]any {
		return map[string]any{"repo_slug": repo, "project_slug": "web-shop", "repo_web_url": "https://example.com/" + repo,
			"trunk_branch": "main", "is_primary": primary, "notes_public": false}
	}
	for _, c := range []struct {
		repo          string
		flag, primary bool
	}{{a, false, true}, {b, false, false}, {b, true, true}, {b, false, true}} {
		if code, out := putRepo(t, e, ws, body(c.repo, c.flag)); code != http.StatusOK || out["is_primary"] != c.primary {
			t.Fatalf("put %s is_primary=%v: %d %v, want primary %v", c.repo, c.flag, code, out, c.primary)
		}
	}
	ps, err := e.st.(store.ReleaseReports).ReleaseProjects(context.Background(), ws)
	if err != nil || len(ps) != 1 || len(ps[0].Repos) != 2 || ps[0].Repos[0].Slug != b || !ps[0].Repos[0].IsPrimary || ps[0].Repos[1].IsPrimary {
		t.Fatalf("projects after the puts: %+v %v, want %s the one primary", ps, err, b)
	}
	if got, err := e.st.(store.WorkspaceRepos).WorkspaceRepo(context.Background(), ws, ""); err != nil || got != b {
		t.Fatalf("the ingest's primary: %q %v, want %s", got, err, b)
	}
	noProject := body(repoOf(ws, "x"), false)
	noProject["project_slug"] = "nosuch"
	for name, c := range map[string]struct {
		token, tenant string
		body          map[string]any
		want          int
	}{
		"no token":            {"", ws, body(a, false), http.StatusUnauthorized},
		"bad token":           {"bad", ws, body(a, false), http.StatusUnauthorized},
		"unknown project":     {"good", ws, noProject, http.StatusNotFound},
		"another's repo slug": {"good", tid, body(a, false), http.StatusConflict},
		"bad slug":            {"good", ws, body("Not/A Slug", false), http.StatusBadRequest},
		"http url":            {"good", ws, map[string]any{"repo_slug": a, "project_slug": "web-shop", "repo_web_url": "http://example.com/x"}, http.StatusBadRequest},
		"unknown field":       {"good", ws, map[string]any{"repo_slug": a, "project_slug": "web-shop", "repo_web_url": "https://example.com/x", "token": "x"}, http.StatusBadRequest},
		"unknown workspace":   {"good", "tnosuch00", body(repoOf("tnosuch00", "x"), false), http.StatusNotFound},
	} {
		if c.tenant == tid {
			putProject(t, e, tid, "web-shop")
		}
		code, out := opCall(t, e, c.tenant, http.MethodPut, "/v1/operator/workspaces/"+c.tenant+"/repos", c.token, c.body)
		if code != c.want {
			t.Errorf("%s: %d %v, want %d", name, code, out, c.want)
		}
	}
	if code, _ := call(t, e, ws, http.MethodPut, "/v1/operator/workspaces/"+ws+"/repos", hum, body(a, true)); code != http.StatusUnauthorized {
		t.Errorf("a member session is not an operator: %d, want 401", code)
	}
}

// The trailer rule reads the repo row's workspace (D3): in the operator
// workspace a trailer-free commit is missing and keeps no body; in any other
// workspace it is skip with its body; a commit with some trailer is derived
// as before in both.
func TestReleaseNotesTrailerRuleByRepoRow(t *testing.T) {
	op := presetTenant()
	e, tid, _ := releaseEnv(t, func(o *hub.Options) { o.OperatorTenant = op })
	createTenant(t, e, op)
	operatorInForce(t, e, op)
	registerRepo(t, e, op, repoOf(op, "main"), true)
	bare, part := releaseSHA("1"), releaseSHA("2")
	msg := "feat(shop): a cart\n\nThe cart keeps its items.\nCloses: WEB-3"
	rows := []map[string]any{releaseRow(bare, "v1.0.0", msg), releaseRow(part, "v1.0.0", "fix(shop): x\n\nLay-What: A fix.")}
	for _, ws := range []string{op, tid} {
		if code, out := opCall(t, e, ws, http.MethodPost, "/v1/operator/release-notes", "good", map[string]any{"tenant": ws, "notes": rows}); code != http.StatusOK || out["stored"].(float64) != 2 {
			t.Fatalf("ingest %s: %d %v", ws, code, out)
		}
	}
	if n := storedNote(t, e, op, "", bare); n.State != "missing" || n.Body != "" {
		t.Fatalf("operator workspace, no trailer: %s %q, want missing and no body", n.State, n.Body)
	}
	if n := storedNote(t, e, tid, "", bare); n.State != "skip" || n.Body != "The cart keeps its items.\nCloses: WEB-3" || n.Subject != "feat(shop): a cart" {
		t.Fatalf("other workspace, no trailer: %s %q %q, want skip with its body", n.State, n.Subject, n.Body)
	}
	for _, ws := range []string{op, tid} {
		if n := storedNote(t, e, ws, "", part); n.State != "missing" || n.Body != "" {
			t.Fatalf("%s, some trailer: %s %q, want missing", ws, n.State, n.Body)
		}
	}
}

// Two repos of one workspace, registered through the operator routes and
// pushed one repo per batch with each repo's own tags: v1.0.0 of one is not
// v1.0.0 of the other, and each repo's versions stay its own.
func TestReleaseNotesTwoReposVersionsPerRepo(t *testing.T) {
	e, _, _ := releaseEnv(t)
	ws, _ := e.tenant()
	putProject(t, e, ws, "web-shop")
	a, b := repoOf(ws, "api"), repoOf(ws, "wui")
	for _, r := range []string{a, b} {
		if code, out := putRepo(t, e, ws, map[string]any{"repo_slug": r, "project_slug": "web-shop", "repo_web_url": "https://example.com/" + r}); code != http.StatusOK {
			t.Fatalf("put %s: %d %v", r, code, out)
		}
	}
	shared := releaseSHA("5")
	push := func(repo string, notes ...map[string]any) {
		t.Helper()
		if code, out := opCall(t, e, ws, http.MethodPost, "/v1/operator/release-notes", "good",
			map[string]any{"tenant": ws, "repo_slug": repo, "notes": notes}); code != http.StatusOK || int(out["stored"].(float64)) != len(notes) {
			t.Fatalf("push %s: %d %v", repo, code, out)
		}
	}
	push(a, releaseRow(shared, "v1.0.0", "feat(api): one"), releaseRow(releaseSHA("6"), "v1.1.0", "feat(api): two"))
	push(b, releaseRow(shared, "v2.0.0", "feat(wui): the same sha, its own tag"), releaseRow(releaseSHA("7"), "v1.0.0", "feat(wui): three"))
	rn := e.st.(store.ReleaseNotes)
	versions := func(repo string) []string {
		rows, err := rn.ListReleaseNotes(context.Background(), ws, repo, "", 10)
		if err != nil {
			t.Fatal(err)
		}
		var out []string
		for _, n := range rows {
			if !slices.Contains(out, n.Version) {
				out = append(out, n.Version)
			}
		}
		slices.Sort(out)
		return out
	}
	if got := versions(a); !slices.Equal(got, []string{"v1.0.0", "v1.1.0"}) {
		t.Fatalf("repo a's versions: %v", got)
	}
	if got := versions(b); !slices.Equal(got, []string{"v1.0.0", "v2.0.0"}) {
		t.Fatalf("repo b's versions: %v", got)
	}
	if n := storedNote(t, e, ws, b, shared); n.Version != "v2.0.0" || n.Subject != "feat(wui): the same sha, its own tag" {
		t.Fatalf("the shared sha in repo b: %+v", n)
	}
	for repo, want := range map[string]string{a: "feat(api): one", b: "feat(wui): three"} {
		of, err := rn.ReleaseNotesOfVersion(context.Background(), ws, repo, "v1.0.0")
		if err != nil || len(of) != 1 || of[0].Subject != want {
			t.Fatalf("%s's v1.0.0: %+v %v, want only %q", repo, of, err, want)
		}
	}
}

// Every row the ingest stores went through buildRows: a banned word in any
// shown field, the body of a trailer-free commit included, is redacted.
// RED CONTROL: store the rows around buildRows (wn.row directly in
// handleIngest) and the banned word stays; this test fails.
func TestReleaseNotesEveryRowFiltered(t *testing.T) {
	t.Setenv(hub.ReleaseNoteBansEnv, "(?i)\\bjane doe\\b")
	e, _, _ := releaseEnv(t)
	ws, _ := e.tenant()
	putProject(t, e, ws, "web-shop")
	repo := repoOf(ws, "api")
	if code, out := putRepo(t, e, ws, map[string]any{"repo_slug": repo, "project_slug": "web-shop", "repo_web_url": "https://example.com/" + repo}); code != http.StatusOK {
		t.Fatalf("put repo: %d %v", code, out)
	}
	sha := releaseSHA("8")
	code, out := opCall(t, e, ws, http.MethodPost, "/v1/operator/release-notes", "good", map[string]any{"tenant": ws, "repo_slug": repo,
		"notes": []map[string]any{releaseRow(sha, "v1.0.0", "fix(api): the cart\n\nJane Doe found it.")}})
	if code != http.StatusOK || out["redacted"].(float64) != 1 {
		t.Fatalf("ingest: %d %v", code, out)
	}
	n := storedNote(t, e, ws, repo, sha)
	if n.State != "skip" || strings.Contains(strings.ToLower(n.Body), "jane") || !strings.Contains(n.Body, "[redacted]") {
		t.Fatalf("the body kept the banned word: %s %q", n.State, n.Body)
	}
}

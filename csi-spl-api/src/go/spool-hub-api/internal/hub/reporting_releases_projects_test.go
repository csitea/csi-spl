package hub_test

import (
	"net/http"
	"testing"
	"time"

	"github.com/csitea/csi-spl/spool-hub-api/internal/hub"
	"github.com/csitea/csi-spl/spool-hub-api/internal/rbac"
)

// Spec 143 releases-projects.md row B-5 (SPL-5772): the projects route, the
// project and repo params, repo_slug on commits, the release note reads per
// repo (primary-only list, repo on {ref}, notes_public for a visitor) and
// the operator's project route. Test: a member of workspace A asking for
// B's project gets 404. RED CONTROL: a visitor's read of a private repo's
// note must be empty (TestReleaseNotesPrivateRepoVisitor).

// b5Two is releaseEnv with a second project "side" whose repo holds one
// commit, beside one commit of the default project's primary repo, both on
// day d0 and both of version v7.5.1.
func b5Two(t *testing.T, mut ...func(*hub.Options)) (e *env, tid, hum, side, mainSHA, sideSHA string, d0 time.Time) {
	t.Helper()
	e, tid, hum = releaseEnv(t, mut...)
	side = repoOf(tid, "side")
	registerOtherProjectRepo(t, e, tid, side)
	d0 = reportDay(t)
	mainSHA, sideSHA = reportSHA(t), reportSHA(t)
	if code, out := ingest(t, e, tid, reportRow(mainSHA, "v7.5.1", "feat(wui): main repo", d0.Add(time.Hour))); code != http.StatusOK {
		t.Fatalf("ingest main: %d %v", code, out)
	}
	if code, out := ingestRepo(t, e, tid, side, reportRow(sideSHA, "v7.5.1", "feat(api): side repo", d0.Add(2*time.Hour))); code != http.StatusOK {
		t.Fatalf("ingest side: %d %v", code, out)
	}
	return e, tid, hum, side, mainSHA, sideSHA, d0
}

// The drop box's list: default first, each project's repos, no operator
// field. A workspace with no project answers configured false; a reader with
// no session is refused.
func TestReleasesProjectsRoute(t *testing.T) {
	e, tid, hum, side, _, _, _ := b5Two(t)
	code, out := call(t, e, tid, http.MethodGet, "/v1/reporting/releases/projects", hum, nil)
	if code != http.StatusOK || out["configured"] != true || out["default"] != "web-shop" {
		t.Fatalf("projects: %d %v", code, out)
	}
	ps := out["projects"].([]any)
	first, second := ps[0].(map[string]any), ps[1].(map[string]any)
	if len(ps) != 2 || first["slug"] != "web-shop" || first["is_default"] != true || second["slug"] != "side" {
		t.Fatalf("projects order: %v", ps)
	}
	repo := second["repos"].([]any)[0].(map[string]any)
	if repo["slug"] != side {
		t.Fatalf("side repo: %v", repo)
	}
	for _, k := range []string{"is_primary", "notes_public", "auth_mode", "github_installation_id", "live_url", "sync_error"} {
		if _, has := repo[k]; has {
			t.Fatalf("the member answer carries %s: %v", k, repo)
		}
	}
	if code, _ := call(t, e, tid, http.MethodGet, "/v1/reporting/releases/projects", "", nil); code != http.StatusForbidden && code != http.StatusUnauthorized {
		t.Fatalf("anonymous projects: %d", code)
	}
	bare, _ := e.tenant()
	code, out = call(t, e, bare, http.MethodGet, "/v1/reporting/releases/projects", seat(t, e, bare, rbac.Developer), nil)
	if ps, ok := out["projects"].([]any); code != http.StatusOK || out["configured"] != false || out["default"] != "" || !ok || len(ps) != 0 {
		t.Fatalf("no project: %d %v, want configured false", code, out)
	}
}

// project picks the project (default: the default one), repo one of its
// repos; each commit names its repo_slug. Bad shapes are 400, a project or
// repo the workspace lacks is 404.
func TestReleasesReportProjectParams(t *testing.T) {
	e, tid, hum, side, mainSHA, sideSHA, d0 := b5Two(t)
	win := "from=" + d0.Format(time.DateOnly) + "&to=" + d0.Format(time.DateOnly)
	for q, want := range map[string]string{"": mainSHA, "project=web-shop&": mainSHA, "project=side&": sideSHA,
		"project=side&repo=" + side + "&": sideSHA, "repo=" + repoOf(tid, "main") + "&": mainSHA} {
		code, out := call(t, e, tid, http.MethodGet, "/v1/reporting/releases/commits?"+q+win, hum, nil)
		notes, _ := out["notes"].([]any)
		if code != http.StatusOK || len(notes) != 1 || notes[0].(map[string]any)["sha"] != want {
			t.Fatalf("commits ?%s: %d %v, want only %s", q, code, out, want)
		}
		if n := notes[0].(map[string]any); n["repo_slug"] == "" || n["repo_slug"] == nil {
			t.Fatalf("commit ?%s carries no repo_slug: %v", q, n)
		}
	}
	code, out := call(t, e, tid, http.MethodGet, "/v1/reporting/releases/daily?project=side&"+win, hum, nil)
	if code != http.StatusOK || out["configured"] != true || out["total_commits"].(float64) != 1 {
		t.Fatalf("daily side: %d %v", code, out)
	}
	if p := out["project"].(map[string]any); p["slug"] != "side" || p["name"] != "Side" || len(out["repos"].([]any)) != 1 {
		t.Fatalf("daily side project and repos: %v", out)
	}
	if day := out["days"].([]any)[0].(map[string]any)["repos"].(map[string]any); len(day) != 1 || day[side].(float64) != 1 {
		t.Fatalf("daily side day repos: %v", day)
	}
	for q, want := range map[string]string{
		"project=Side!":                 "bad_query",
		"repo=nope":                     "bad_query",
		"project=nope":                  "unknown_project",
		"project=web-shop&repo=" + side: "unknown_repo",
		"repo=csitea/nope":              "unknown_repo",
	} {
		for _, path := range []string{"/v1/reporting/releases/daily?", "/v1/reporting/releases/commits?"} {
			code, out := call(t, e, tid, http.MethodGet, path+q, hum, nil)
			if out["error"] != want || (want == "bad_query") != (code == http.StatusBadRequest) || (want != "bad_query") != (code == http.StatusNotFound) {
				t.Errorf("%s%s: %d %v, want %s", path, q, code, out, want)
			}
		}
	}
}

// A member of workspace A naming workspace B's project or repo gets 404,
// the answer of a project that does not exist. CONTROL: B's member reads it.
func TestReleasesReportOtherWorkspaceProject404(t *testing.T) {
	e, a, humA := releaseEnv(t)
	b, _ := e.tenant()
	bRepo := repoOf(b, "side")
	registerOtherProjectRepo(t, e, b, bRepo)
	humB := seat(t, e, b, rbac.Developer)
	for path, want := range map[string]string{
		"/v1/reporting/releases/daily?project=side":   "unknown_project",
		"/v1/reporting/releases/commits?project=side": "unknown_project",
		"/v1/reporting/releases/daily?repo=" + bRepo:  "unknown_repo",
	} {
		if code, out := call(t, e, a, http.MethodGet, path, humA, nil); code != http.StatusNotFound || out["error"] != want {
			t.Errorf("A asks %s: %d %v, want 404 %s", path, code, out, want)
		}
		if code, out := call(t, e, b, http.MethodGet, path, humB, nil); code != http.StatusOK {
			t.Errorf("B asks %s: %d %v, want 200", path, code, out)
		}
	}
}

// RED CONTROL of row B-5: a visitor (no member session) on the page of a
// workspace whose repo is not notes_public reads nothing of it, and the
// member reads all of it. A handler that answers the visitor as a member
// fails the first check below.
func TestReleaseNotesPrivateRepoVisitor(t *testing.T) {
	e, _, _ := releaseEnv(t, func(o *hub.Options) { o.OriginTenant = hub.NewOriginTenant("{tenant}"+domain, "") })
	priv, _ := e.tenant()
	registerRepo(t, e, priv, repoOf(priv, "main"), true)
	hum := seat(t, e, priv, rbac.Developer)
	sha := releaseSHA("c")
	if code, out := ingest(t, e, priv, releaseRow(sha, "v7.6.1", releaseFullMsg)); code != http.StatusOK || out["stored"].(float64) != 1 {
		t.Fatalf("ingest: %d %v", code, out)
	}
	for path, want := range map[string]int{"/v1/release-notes/" + sha: http.StatusNotFound, "/v1/release-notes/v7.6.1": http.StatusNotFound,
		"/v1/release-notes/" + sha + "?repo=" + repoOf(priv, "main"): http.StatusNotFound, "/v1/release-notes?limit=5": http.StatusOK} {
		code, out := visitorGet(t, e, "api"+domain, "https://"+priv+domain, path)
		if vs, _ := out["versions"].([]any); code != want || len(vs) != 0 || out["note"] != nil || out["notes"] != nil {
			t.Fatalf("visitor %s of a private repo = %d %v, want %d and nothing", path, code, out, want)
		}
		if code, out := call(t, e, priv, http.MethodGet, path, hum, nil); code != http.StatusOK || (out["note"] == nil && out["notes"] == nil && len(out["versions"].([]any)) != 1) {
			t.Fatalf("member %s = %d %v, want the note", path, code, out)
		}
	}
}

// The list and a version read the primary repo only; repo on {ref} opens
// another repo's note, for a member, and for a visitor only when that repo
// is notes_public (the side repo is not).
func TestReleaseNotesPrimaryRepoAndRepoParam(t *testing.T) {
	e, tid, hum, side, mainSHA, sideSHA, _ := b5Two(t, func(o *hub.Options) { o.OriginTenant = hub.NewOriginTenant("{tenant}"+domain, "") })
	code, out := call(t, e, tid, http.MethodGet, "/v1/release-notes/v7.5.1", hum, nil)
	if notes, _ := out["notes"].([]any); code != http.StatusOK || len(notes) != 1 || notes[0].(map[string]any)["sha"] != mainSHA {
		t.Fatalf("v7.5.1 of the primary repo: %d %v", code, out)
	}
	code, out = call(t, e, tid, http.MethodGet, "/v1/release-notes?limit=50", hum, nil)
	for _, v := range out["versions"].([]any) {
		for _, n := range v.(map[string]any)["notes"].([]any) {
			if n.(map[string]any)["sha"] == sideSHA {
				t.Fatalf("the list carries the side repo's note: %v", v)
			}
		}
	}
	if code != http.StatusOK {
		t.Fatalf("list: %d %v", code, out)
	}
	if code, out := call(t, e, tid, http.MethodGet, "/v1/release-notes/"+sideSHA, hum, nil); code != http.StatusNotFound {
		t.Fatalf("side sha with no repo param: %d %v, want 404 (primary only)", code, out)
	}
	n := noteOf(t, e, tid, hum, sideSHA+"?repo="+side)
	if n["sha"] != sideSHA || n["repo_slug"] != side {
		t.Fatalf("member side note: %v", n)
	}
	if code, out := visitorGet(t, e, "api"+domain, "https://"+tid+domain, "/v1/release-notes/"+sideSHA+"?repo="+side); code != http.StatusNotFound {
		t.Fatalf("visitor of the private side repo: %d %v, want 404", code, out)
	}
	if code, out := visitorGet(t, e, "api"+domain, "https://"+tid+domain, "/v1/release-notes/"+mainSHA); code != http.StatusOK {
		t.Fatalf("visitor of the public primary repo: %d %v, want 200 (CONTROL)", code, out)
	}
	if code, out := call(t, e, tid, http.MethodGet, "/v1/release-notes/"+sideSHA+"?repo=csitea/other", hum, nil); code != http.StatusNotFound {
		t.Fatalf("a repo of no project: %d %v, want 404", code, out)
	}
	if code, out := call(t, e, tid, http.MethodGet, "/v1/release-notes/"+sideSHA+"?repo=bad", hum, nil); code != http.StatusBadRequest {
		t.Fatalf("bad repo shape: %d %v, want 400", code, out)
	}
}

// The operator registers a project: the operator token only, the default
// moves on is_default, and the drop box then lists it first.
func TestOperatorProjectPut(t *testing.T) {
	e, tid, hum := releaseEnv(t)
	registerOtherProjectRepo(t, e, tid, repoOf(tid, "side"))
	path := "/v1/operator/workspaces/" + tid + "/projects/side"
	body := map[string]any{"name": "Side B", "is_default": true}
	if code, out := opCall(t, e, tid, http.MethodPut, path, "good", body); code != http.StatusOK || out["is_default"] != true || out["name"] != "Side B" {
		t.Fatalf("put side: %d %v", code, out)
	}
	code, out := call(t, e, tid, http.MethodGet, "/v1/reporting/releases/projects", hum, nil)
	if first := out["projects"].([]any)[0].(map[string]any); code != http.StatusOK || out["default"] != "side" || first["name"] != "Side B" {
		t.Fatalf("projects after the put: %d %v", code, out)
	}
	fresh, _ := e.tenant()
	if code, out := opCall(t, e, fresh, http.MethodPut, "/v1/operator/workspaces/"+fresh+"/projects/first", "good", map[string]any{"name": "First"}); code != http.StatusOK || out["is_default"] != true {
		t.Fatalf("a workspace's first project: %d %v, want the default", code, out)
	}
	for name, c := range map[string]struct {
		token, path string
		body        any
		want        int
	}{
		"no token":          {"", path, body, http.StatusUnauthorized},
		"bad slug":          {"good", "/v1/operator/workspaces/" + tid + "/projects/Side", body, http.StatusBadRequest},
		"no name":           {"good", path, map[string]any{"name": ""}, http.StatusBadRequest},
		"unknown field":     {"good", path, map[string]any{"name": "x", "repo": "y"}, http.StatusBadRequest},
		"unknown workspace": {"good", "/v1/operator/workspaces/tnosuch00/projects/side", body, http.StatusNotFound},
	} {
		if code, out := opCall(t, e, tid, http.MethodPut, c.path, c.token, c.body); code != c.want {
			t.Errorf("%s: %d %v, want %d", name, code, out, c.want)
		}
	}
	if code, _ := call(t, e, tid, http.MethodPut, path, hum, body); code != http.StatusUnauthorized {
		t.Errorf("a member session is not an operator: %d", code)
	}
}

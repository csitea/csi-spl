package store

import (
	"context"
	"errors"
	"strings"
	"testing"
	"time"
)

// Spec 143 releases-projects.md row B-6 (SPL-5801), the store half: the
// operator's repo write and the body of a trailer-free row.

// The repo write: the first repo is the primary, true moves it, false keeps
// it; a re-put moves a repo between projects; a project the workspace lacks
// and a slug another workspace holds are refused; a bad row is refused
// before the write.
func TestPutWorkspaceRepo(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			w := st.(WorkspaceRepoWriter)
			tenant, other := newTenant(t, st), newTenant(t, st)
			for _, p := range []string{"web-shop", "blog"} {
				if _, err := st.(SoftwareProjects).PutSoftwareProject(ctx, tenant, p, p, false); err != nil {
					t.Fatal(err)
				}
			}
			a, b := b4Repo(), b4Repo()
			put := func(repo, project string, primary bool) (bool, error) {
				return w.PutWorkspaceRepo(ctx, WorkspaceRepoPut{Tenant: tenant, Slug: repo, Project: project,
					WebURL: "https://example.com/" + repo, IsPrimary: primary, NotesPublic: repo == a})
			}
			for _, c := range []struct {
				repo, project string
				flag, want    bool
			}{{a, "web-shop", false, true}, {b, "web-shop", false, false}, {b, "blog", true, true}, {b, "blog", false, true}} {
				if got, err := put(c.repo, c.project, c.flag); err != nil || got != c.want {
					t.Fatalf("put %s under %s primary=%v: %v %v, want %v", c.repo, c.project, c.flag, got, err, c.want)
				}
			}
			ps, err := st.(ReleaseReports).ReleaseProjects(ctx, tenant)
			if err != nil || len(ps) != 2 {
				t.Fatalf("projects: %+v %v", ps, err)
			}
			for _, p := range ps {
				if len(p.Repos) != 1 {
					t.Fatalf("project %s: %+v, want one repo each", p.Slug, p.Repos)
				}
				r := p.Repos[0]
				if (p.Slug == "blog") != (r.Slug == b) || r.IsPrimary != (r.Slug == b) || r.NotesPublic != (r.Slug == a) || r.TrunkBranch != "main" {
					t.Fatalf("project %s: %+v, want b under blog the primary", p.Slug, r)
				}
			}
			if got, err := st.(WorkspaceRepos).WorkspaceRepo(ctx, tenant, ""); err != nil || got != b {
				t.Fatalf("primary: %q %v, want %s", got, err, b)
			}
			if _, err := put(b4Repo(), "nosuch", false); !errors.Is(err, ErrNoProject) {
				t.Fatalf("unknown project: %v, want ErrNoProject", err)
			}
			if _, err := st.(SoftwareProjects).PutSoftwareProject(ctx, other, "web-shop", "x", false); err != nil {
				t.Fatal(err)
			}
			if _, err := w.PutWorkspaceRepo(ctx, WorkspaceRepoPut{Tenant: other, Slug: a, Project: "web-shop", WebURL: "https://example.com/x"}); !errors.Is(err, ErrRepoTaken) {
				t.Fatalf("another workspace's slug: %v, want ErrRepoTaken", err)
			}
			for _, bad := range []WorkspaceRepoPut{
				{Tenant: tenant, Slug: "NoSlash", Project: "web-shop", WebURL: "https://example.com/x"},
				{Tenant: tenant, Slug: b4Repo(), Project: "web-shop", WebURL: "http://example.com/x"},
				{Tenant: tenant, Slug: b4Repo(), Project: "web-shop", WebURL: "https://example.com/x", AuthMode: "token"},
				{Tenant: tenant, Slug: b4Repo(), Project: "web-shop", WebURL: "https://example.com/x", TrunkBranch: "-x"},
			} {
				if _, err := w.PutWorkspaceRepo(ctx, bad); err == nil {
					t.Fatalf("put %+v: accepted", bad)
				}
			}
		})
	}
}

// A row's body is stored and read back, and a re-put replaces it; the check
// refuses a body over 2000 bytes.
func TestReleaseNoteBody(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			tenant, repo := newTenant(t, st), b4Repo()
			at := time.Date(2094, 7, 8, 9, 0, 0, 0, time.UTC)
			n := noteOK(randSHA(), "v1.0.0", at)
			n.State, n.Body = "skip", "The cart keeps its items.\nCloses: WEB-3"
			b4Put(t, st, tenant, repo, n)
			got, err := st.(ReleaseNotes).ReleaseNote(ctx, tenant, repo, n.SHA)
			if err != nil || got.Body != n.Body {
				t.Fatalf("body: %q %v, want %q", got.Body, err, n.Body)
			}
			n.Body = ""
			b4Put(t, st, tenant, repo, n)
			if got, err := st.(ReleaseNotes).ReleaseNote(ctx, tenant, repo, n.SHA); err != nil || got.Body != "" {
				t.Fatalf("a re-put without a body: %q %v", got.Body, err)
			}
			n.Body = strings.Repeat("x", ReleaseBodyMax+1)
			if why := CheckReleaseNote(n); why == "" {
				t.Fatal("a 2001-byte body passed the check")
			}
		})
	}
}

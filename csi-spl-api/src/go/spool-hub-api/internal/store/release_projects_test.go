package store

import (
	"context"
	"errors"
	"slices"
	"testing"
	"time"

	"github.com/jackc/pgx/v5"
)

// Spec 143 releases-projects.md row B-4 (SPL-5705): the store answers per
// software project. Test: one project's report excludes the other's commits;
// two repos' v1.0.0 count as 2. Red control: an empty Repos is an error, and
// a store that reads everything on it fails TestReleaseReportNoReposRefused.

// b4Repo is a repo slug of its own: a slug is unique across workspaces (rdb 0266).
func b4Repo() string { return "csitea/" + uid("b4-") }

// seedProjectRepo registers repo under project of tenant on either driver.
func seedProjectRepo(t *testing.T, st Store, tenant, project string, isDefault bool, repo string, primary bool) {
	t.Helper()
	switch s := st.(type) {
	case *Memory:
		s.SeedProjectRepo(tenant, project, "Name "+project, isDefault,
			ReleaseProjectRepo{Slug: repo, WebURL: "https://example.com/" + repo, CommitPath: "/commit/", TrunkBranch: "main", SyncStatus: "pending"}, primary)
	case *Postgres:
		ctx := context.Background()
		err := s.asOperator(ctx, func(tx pgx.Tx) error {
			if _, err := tx.Exec(ctx, `INSERT INTO software_projects (tenant_id, project_slug, name, is_default)
				VALUES ($1, $2, 'Name ' || $2, $3) ON CONFLICT DO NOTHING`, tenant, project, isDefault); err != nil {
				return err
			}
			_, err := tx.Exec(ctx, `INSERT INTO workspace_repos (tenant_id, repo_slug, project_slug, repo_web_url, is_primary)
				VALUES ($1, $2, $3, 'https://example.com/' || $2, $4)`, tenant, repo, project, primary)
			return err
		})
		if err != nil {
			t.Fatal(err)
		}
	default:
		t.Fatalf("no project seed for %T", st)
	}
}

func slugsOf(ps []ReleaseProject) []string {
	out := []string{}
	for _, p := range ps {
		out = append(out, p.Slug)
	}
	return out
}

// The projects of a workspace: default first, then by name, primary repo
// first; another workspace's project is not listed.
func TestReleaseProjectsList(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rr := st.(ReleaseReports)
			a, b := newTenant(t, st), newTenant(t, st)
			main, side, blog := b4Repo(), b4Repo(), b4Repo()
			seedProjectRepo(t, st, a, "zz-blog", false, blog, false)
			seedProjectRepo(t, st, a, "web-shop", true, side, false)
			seedProjectRepo(t, st, a, "web-shop", true, main, true)
			seedProjectRepo(t, st, b, "theirs", true, b4Repo(), true)
			if got, err := rr.ReleaseProjects(ctx, a); err != nil || !slices.Equal(slugsOf(got), []string{"web-shop", "zz-blog"}) {
				t.Fatalf("projects of a: %v %v", slugsOf(got), err)
			} else if !got[0].IsDefault || !slices.Equal(got[0].RepoSlugs(), []string{main, side}) || got[0].Repos[0].WebURL != "https://example.com/"+main {
				t.Fatalf("default project: %+v", got[0])
			}
			if got, err := rr.ReleaseProjects(ctx, newTenant(t, st)); err != nil || len(got) != 0 {
				t.Fatalf("a workspace with no project: %v %v", got, err)
			}
			if _, err := rr.ReleaseProjects(ctx, ""); !errors.Is(err, ErrNoTenant) {
				t.Fatalf("no tenant: %v", err)
			}
		})
	}
}

// A project with no repo yet is not listed (Postgres: the memory seam has no
// empty project).
func TestReleaseProjectsSkipsEmptyProject(t *testing.T) {
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			pg, ctx := scopePostgres(t, st), context.Background()
			a := newTenant(t, st)
			if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
				_, err := tx.Exec(ctx, `INSERT INTO software_projects (tenant_id, project_slug, name, is_default) VALUES ($1, 'empty', 'Empty', true)`, a)
				return err
			}); err != nil {
				t.Fatal(err)
			}
			if got, err := pg.ReleaseProjects(ctx, a); err != nil || len(got) != 0 {
				t.Fatalf("a project with no repo: %+v %v", got, err)
			}
		})
	}
}

// b4Put stores notes in one repo of tenant.
func b4Put(t *testing.T, st Store, tenant, repo string, notes ...ReleaseNote) {
	t.Helper()
	if err := st.(ReleaseNotes).PutReleaseNotes(context.Background(), tenant, repo, notes, notes[0].CommittedAt); err != nil {
		t.Fatal(err)
	}
}

// One project's report excludes the other project's commits, and the same
// version in two repos counts twice.
func TestReleaseReportPerProject(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rr := st.(ReleaseReports)
			tenant := newTenant(t, st)
			d0 := reportWindow(t)
			api, wui, other := b4Repo(), b4Repo(), b4Repo()
			b4Put(t, st, tenant, api, reportNote("v1.0.0", "feat", "api", "feat(api): one", d0.Add(time.Hour)))
			b4Put(t, st, tenant, wui, reportNote("v1.0.0", "feat", "wui", "feat(wui): two", d0.Add(2*time.Hour)),
				reportNote("", "fix", "wui", "fix(wui): unreleased", d0.Add(3*time.Hour)))
			otherNote := reportNote("v1.0.0", "feat", "blog", "feat(blog): other project", d0.Add(4*time.Hour))
			b4Put(t, st, tenant, other, otherNote)
			f := ReleaseReportFilter{Tenant: tenant, From: d0, To: d0.AddDate(0, 0, 1), Repos: []string{api, wui}}
			got, err := rr.ReleaseDaily(ctx, f)
			if err != nil {
				t.Fatal(err)
			}
			if got.TotalCommits != 3 || got.TotalVersions != 2 || got.UnreleasedCommits != 1 || len(got.Days) != 1 {
				t.Fatalf("web-shop daily: %+v, want 3 commits, 2 versions (api and wui v1.0.0), 1 unreleased", got)
			}
			if r := got.Days[0].Repos; len(r) != 2 || r[api] != 1 || r[wui] != 2 {
				t.Fatalf("per-repo day counts: %v", r)
			}
			notes, total, err := rr.ReleaseCommits(ctx, f)
			if err != nil || total != 3 || slices.ContainsFunc(notes, func(n ReleaseNote) bool { return n.SHA == otherNote.SHA }) {
				t.Fatalf("web-shop commits: %d %v, carry the other project's %s", total, err, otherNote.SHA)
			}
			f.Repos = []string{other}
			if got, err := rr.ReleaseDaily(ctx, f); err != nil || got.TotalCommits != 1 || got.TotalVersions != 1 || got.UnreleasedCommits != 0 {
				t.Fatalf("blog daily: %+v %v", got, err)
			}
		})
	}
}

// A day's deploys are those of the selected repos, each naming its repo.
func TestReleaseReportDeploysPerRepo(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rr := st.(ReleaseReports)
			tenant := newTenant(t, st)
			mine, theirs := b4Repo(), b4Repo()
			now := time.Now().UTC()
			for _, repo := range []string{mine, theirs} {
				b4Deploy(t, st, scopeDeploy(tenant, repo, randSHA(), ""), now)
			}
			got, err := rr.ReleaseDaily(ctx, ReleaseReportFilter{Tenant: tenant, From: now.Add(-time.Hour), To: now.Add(time.Hour), Repos: []string{mine}})
			if err != nil {
				t.Fatal(err)
			}
			var deps []ReleaseDeploy
			for _, d := range got.Days {
				deps = append(deps, d.Deploys...)
			}
			if len(deps) != 1 || deps[0].RepoSlug != mine {
				t.Fatalf("deploys of %s: %+v", mine, deps)
			}
		})
	}
}

// b4Deploy records d on either driver.
func b4Deploy(t *testing.T, st Store, d EstateDeploy, at time.Time) {
	t.Helper()
	switch s := st.(type) {
	case *Memory:
		memDeployMu.Lock()
		memDeploys[s] = append(memDeploys[s], ReleaseDeploy{TenantID: d.TenantID, RepoSlug: d.RepoSlug, Env: d.Env, Component: d.Component,
			Version: d.Version, CommitSHA: d.CommitSHA, DeployedAt: at, Status: d.Status, Source: "ci"})
		memDeployMu.Unlock()
	case *Postgres:
		if _, _, err := s.PutEstateDeploy(context.Background(), d); err != nil {
			t.Fatal(err)
		}
	}
}

// RED CONTROL of row B-4: an empty Repos is ErrNoRepos on both reads, and
// nothing is read. A store that reads every repo on it fails here.
func TestReleaseReportNoReposRefused(t *testing.T) {
	ctx := context.Background()
	for name, st := range drivers(t) {
		t.Run(name, func(t *testing.T) {
			rr := st.(ReleaseReports)
			tenant := newTenant(t, st)
			d0 := reportWindow(t)
			b4Put(t, st, tenant, b4Repo(), reportNote("v1.0.0", "feat", "api", "feat(api): one", d0.Add(time.Hour)))
			for _, repos := range [][]string{nil, {}} {
				f := ReleaseReportFilter{Tenant: tenant, From: d0, To: d0.AddDate(0, 0, 1), Repos: repos}
				daily, err := rr.ReleaseDaily(ctx, f)
				if !errors.Is(err, ErrNoRepos) || daily.TotalCommits != 0 {
					t.Fatalf("daily with Repos %#v: %d commits, err %v; want ErrNoRepos and nothing read", repos, daily.TotalCommits, err)
				}
				notes, total, err := rr.ReleaseCommits(ctx, f)
				if !errors.Is(err, ErrNoRepos) || total != 0 || len(notes) != 0 {
					t.Fatalf("commits with Repos %#v: %d, err %v; want ErrNoRepos and nothing read", repos, total, err)
				}
			}
			if err := CheckReleaseReportFilter(ReleaseReportFilter{Tenant: tenant, From: d0, To: d0.AddDate(0, 0, 1), Repos: []string{"Not A Slug"}}); err == nil {
				t.Fatal("a bad repo slug was accepted")
			}
		})
	}
}

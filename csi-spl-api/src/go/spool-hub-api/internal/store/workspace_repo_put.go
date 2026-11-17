package store

import (
	"context"
	"errors"
	"regexp"
	"slices"

	"github.com/jackc/pgx/v5"
)

// The operator's registration of a workspace's repo (spec 143
// releases-projects.md section 4.5, row B-6): spec 171's
// PUT /v1/operator/workspaces/{id}/repos with a required project. Only the
// operator registers (section 9, answer 2): rdb 0266 lets only the operator
// scope write workspace_repos, and this write runs there.

// ErrRepoTaken: the repo slug is registered by another workspace (rdb 0266
// workspace_repos_slug_once, section 9 answer 3: each repo in one workspace).
var ErrRepoTaken = errors.New("repo registered by another workspace")

// ErrNoProject: the workspace has no software project of that slug.
var ErrNoProject = errors.New("no such software project")

// WorkspaceRepoAuthModes is rdb 0266's auth_mode CHECK.
var WorkspaceRepoAuthModes = []string{"github_app", "pat_kms", "public", "ingest_only"}

// WorkspaceRepoPut is one registration. AuthMode "" is github_app and
// TrunkBranch "" is main, the table's defaults.
type WorkspaceRepoPut struct {
	Tenant      string
	Slug        string
	Project     string
	WebURL      string
	TrunkBranch string
	AuthMode    string
	IsPrimary   bool
	NotesPublic bool
}

// WorkspaceRepoWriter is the operator's write of a workspace's repos.
type WorkspaceRepoWriter interface {
	// PutWorkspaceRepo creates or updates the repo of r.Tenant under r.Project.
	// A workspace's first repo becomes its primary whatever IsPrimary says;
	// IsPrimary true moves the primary to it, and false never moves it away.
	// Answers whether it is the primary after the write. ErrNoProject when the
	// project is not the workspace's, ErrRepoTaken when another workspace
	// holds the slug.
	PutWorkspaceRepo(ctx context.Context, r WorkspaceRepoPut) (bool, error)
}

var (
	_ WorkspaceRepoWriter = (*Postgres)(nil)
	_ WorkspaceRepoWriter = (*Memory)(nil)
)

var (
	workspaceRepoSlugRe   = regexp.MustCompile(`^[a-z0-9._-]+/[a-z0-9._-]+$`)
	workspaceRepoURLRe    = regexp.MustCompile(`^https://[^\s/]+(/\S*)?$`)
	workspaceRepoBranchRe = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9._/-]{0,99}$`)
)

// CheckWorkspaceRepo names the first thing a repo write may not carry, the
// Go side of rdb 0266's CHECKs, and fills the defaults.
func CheckWorkspaceRepo(r *WorkspaceRepoPut) error {
	if r.TrunkBranch == "" {
		r.TrunkBranch = "main"
	}
	if r.AuthMode == "" {
		r.AuthMode = "github_app"
	}
	switch {
	case checkTenant(r.Tenant) != nil:
		return ErrNoTenant
	case len(r.Slug) > 140 || !workspaceRepoSlugRe.MatchString(r.Slug):
		return errors.New("repo_slug must be a lowercase owner/name")
	case !softwareProjectSlugRe.MatchString(r.Project):
		return errors.New("project_slug must be 1..48 lowercase letters, digits or -, starting with a letter or digit")
	case len(r.WebURL) > ReleaseLinkMax || !workspaceRepoURLRe.MatchString(r.WebURL):
		return errors.New("repo_web_url must be an https URL")
	case !workspaceRepoBranchRe.MatchString(r.TrunkBranch):
		return errors.New("trunk_branch must be a branch name")
	case !slices.Contains(WorkspaceRepoAuthModes, r.AuthMode):
		return errors.New("auth_mode must be github_app, pat_kms, public or ingest_only")
	}
	return nil
}

// PutWorkspaceRepo is WorkspaceRepoWriter on Postgres: one operator-scope
// transaction, serialised per workspace so two writes never both take the
// primary.
func (s *Postgres) PutWorkspaceRepo(ctx context.Context, r WorkspaceRepoPut) (bool, error) {
	if err := CheckWorkspaceRepo(&r); err != nil {
		return false, err
	}
	var primary bool
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('workspace_repos:' || $1))`, r.Tenant); err != nil {
			return err
		}
		var project, taken, other bool
		if err := tx.QueryRow(ctx, `SELECT
			EXISTS (SELECT 1 FROM software_projects WHERE tenant_id = $1 AND project_slug = $3),
			EXISTS (SELECT 1 FROM workspace_repos WHERE repo_slug = $2 AND tenant_id <> $1),
			EXISTS (SELECT 1 FROM workspace_repos WHERE tenant_id = $1 AND is_primary AND repo_slug <> $2)`,
			r.Tenant, r.Slug, r.Project).Scan(&project, &taken, &other); err != nil {
			return err
		}
		switch {
		case !project:
			return ErrNoProject
		case taken:
			return ErrRepoTaken
		}
		primary = r.IsPrimary || !other
		if r.IsPrimary && other {
			if _, err := tx.Exec(ctx, `UPDATE workspace_repos SET is_primary = false, updated_at = now()
				WHERE tenant_id = $1 AND is_primary AND repo_slug <> $2`, r.Tenant, r.Slug); err != nil {
				return err
			}
		}
		_, err := tx.Exec(ctx, `INSERT INTO workspace_repos (tenant_id, repo_slug, project_slug, repo_web_url,
			trunk_branch, auth_mode, is_primary, notes_public)
			VALUES ($1, $2, $3, $4, $5, $6, $7, $8)
			ON CONFLICT (tenant_id, repo_slug) DO UPDATE SET project_slug = EXCLUDED.project_slug,
				repo_web_url = EXCLUDED.repo_web_url, trunk_branch = EXCLUDED.trunk_branch,
				auth_mode = EXCLUDED.auth_mode, is_primary = EXCLUDED.is_primary,
				notes_public = EXCLUDED.notes_public, updated_at = now()`,
			r.Tenant, r.Slug, r.Project, r.WebURL, r.TrunkBranch, r.AuthMode, primary, r.NotesPublic)
		return err
	})
	return primary, err
}

// PutWorkspaceRepo is WorkspaceRepoWriter on the memory store, the Postgres
// rules, writing both memory registries (WorkspaceRepo's and the projects').
func (s *Memory) PutWorkspaceRepo(_ context.Context, r WorkspaceRepoPut) (bool, error) {
	if err := CheckWorkspaceRepo(&r); err != nil {
		return false, err
	}
	memProjectMu.Lock()
	defer memProjectMu.Unlock()
	memRepoMu.Lock()
	defer memRepoMu.Unlock()
	if memProjects[s][r.Tenant][r.Project] == nil {
		return false, ErrNoProject
	}
	for t, repos := range memRepos[s] {
		if _, ok := repos[r.Slug]; ok && t != r.Tenant {
			return false, ErrRepoTaken
		}
	}
	if memRepos[s] == nil {
		memRepos[s] = map[string]map[string]bool{}
	}
	repos := memRepos[s][r.Tenant]
	if repos == nil {
		repos = map[string]bool{}
		memRepos[s][r.Tenant] = repos
	}
	other := false
	for slug, p := range repos {
		other = other || (p && slug != r.Slug)
	}
	primary := r.IsPrimary || !other
	for slug := range repos {
		if primary && slug != r.Slug {
			repos[slug] = false
		}
	}
	repos[r.Slug] = primary
	memMoveProjectRepo(memProjects[s][r.Tenant], r, primary)
	return primary, nil
}

// memMoveProjectRepo puts r under its project only, its flags set, and
// clears the primary of every other repo when r is the primary.
func memMoveProjectRepo(ps map[string]*memProject, r WorkspaceRepoPut, primary bool) {
	for _, p := range ps {
		p.Repos = slices.DeleteFunc(p.Repos, func(x ReleaseProjectRepo) bool { return x.Slug == r.Slug })
		if primary {
			p.primary = ""
			for i := range p.Repos {
				p.Repos[i].IsPrimary = false
			}
		}
	}
	p := ps[r.Project]
	p.Repos = append(p.Repos, ReleaseProjectRepo{Slug: r.Slug, WebURL: r.WebURL, CommitPath: "/commit/",
		TrunkBranch: r.TrunkBranch, SyncStatus: "pending", IsPrimary: primary, NotesPublic: r.NotesPublic})
	if primary {
		p.primary = r.Slug
	}
}

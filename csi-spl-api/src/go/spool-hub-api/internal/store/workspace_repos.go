package store

import (
	"context"
	"errors"
	"sync"

	"github.com/jackc/pgx/v5"
)

// The repos of a workspace (rdb 0266 workspace_repos), read only as far as the
// release note and deploy writers need (spec 143 releases-projects.md row B-2).

// ErrRepoNotRegistered: the workspace has no primary repo, or not the named one.
var ErrRepoNotRegistered = errors.New("repo not registered")

// WorkspaceRepos resolves the repo a commit or a deploy belongs to.
type WorkspaceRepos interface {
	// WorkspaceRepo is slug when tenant registered it, and tenant's primary
	// repo for slug "". ErrRepoNotRegistered when there is none.
	WorkspaceRepo(ctx context.Context, tenant, slug string) (string, error)
}

var (
	_ WorkspaceRepos = (*Postgres)(nil)
	_ WorkspaceRepos = (*Memory)(nil)
)

// WorkspaceRepo is WorkspaceRepos on Postgres, in tenant's own scope.
func (s *Postgres) WorkspaceRepo(ctx context.Context, tenant, slug string) (string, error) {
	var out string
	err := s.queryRowTenant(ctx, tenant, `SELECT repo_slug FROM workspace_repos
		WHERE tenant_id = $1 AND CASE WHEN $2::text = '' THEN is_primary ELSE repo_slug = $2::text END`,
		[]any{tenant, slug}, &out)
	if errors.Is(err, pgx.ErrNoRows) {
		return "", ErrRepoNotRegistered
	}
	return out, err
}

// Memory side: a per-store map beside the Memory struct, as memReleases.
var (
	memRepoMu sync.Mutex
	memRepos  = map[*Memory]map[string]map[string]bool{}
)

// SeedWorkspaceRepo registers a repo of tenant on the memory store, which has
// no registration route; primary marks the one a slug-less write lands in.
func (s *Memory) SeedWorkspaceRepo(tenant, slug string, primary bool) {
	memRepoMu.Lock()
	defer memRepoMu.Unlock()
	if memRepos[s] == nil {
		memRepos[s] = map[string]map[string]bool{}
	}
	if memRepos[s][tenant] == nil {
		memRepos[s][tenant] = map[string]bool{}
	}
	memRepos[s][tenant][slug] = primary
}

// WorkspaceRepo is WorkspaceRepos on the memory store.
func (s *Memory) WorkspaceRepo(_ context.Context, tenant, slug string) (string, error) {
	if err := checkTenant(tenant); err != nil {
		return "", err
	}
	memRepoMu.Lock()
	defer memRepoMu.Unlock()
	for r, primary := range memRepos[s][tenant] {
		if (slug == "" && primary) || r == slug {
			return r, nil
		}
	}
	return "", ErrRepoNotRegistered
}

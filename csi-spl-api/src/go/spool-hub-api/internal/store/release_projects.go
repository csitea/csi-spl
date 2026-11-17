package store

import (
	"cmp"
	"context"
	"errors"
	"regexp"
	"slices"
	"sync"
	"time"
	"unicode/utf8"

	"github.com/jackc/pgx/v5"
)

// The software projects of a workspace as the Releases tab lists them (spec
// 143 releases-projects.md sections 4 and 6.1, row B-4): rdb 0266's
// software_projects joined with workspace_repos, read in the workspace's own
// scope. A project with no repo yet is left out, so "1 or many repos" holds
// for what a member sees. auth_mode, github_installation_id, live_url and
// sync_error stay out of the answer (section 6.1).

// ReleaseProjectRepo is one repo of a project as a member reads it.
type ReleaseProjectRepo struct {
	Slug         string     `json:"slug"`
	WebURL       string     `json:"web_url"`
	CommitPath   string     `json:"commit_path"`
	TrunkBranch  string     `json:"trunk_branch"`
	SyncStatus   string     `json:"sync_status"`
	LastSyncedAt *time.Time `json:"last_synced_at"`
	// IsPrimary and NotesPublic decide the release note reads (section
	// 6.3): the modal and the Flow read the primary repo, and a reader with
	// no member session only a notes_public one. Neither is in the answer.
	IsPrimary   bool `json:"-"`
	NotesPublic bool `json:"-"`
}

// ReleaseProject is one software project and its repos, primary repo first,
// then by slug.
type ReleaseProject struct {
	Slug      string               `json:"slug"`
	Name      string               `json:"name"`
	IsDefault bool                 `json:"is_default"`
	Repos     []ReleaseProjectRepo `json:"repos"`
}

// RepoSlugs is the project's repo slugs, the Repos of a report filter.
func (p ReleaseProject) RepoSlugs() []string {
	out := make([]string, 0, len(p.Repos))
	for _, r := range p.Repos {
		out = append(out, r.Slug)
	}
	return out
}

// ReleaseProjects is ReleaseReports.ReleaseProjects on Postgres: one join,
// in tenant's scope, rows grouped into projects in their order.
func (s *Postgres) ReleaseProjects(ctx context.Context, tenant string) ([]ReleaseProject, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	out := []ReleaseProject{}
	err := s.queryTenant(ctx, tenant, `SELECT p.project_slug, p.name, p.is_default, r.repo_slug, r.repo_web_url,
		r.repo_commit_path, r.trunk_branch, r.sync_status, r.last_synced_at, r.is_primary, r.notes_public
		FROM software_projects p
		JOIN workspace_repos r ON r.tenant_id = p.tenant_id AND r.project_slug = p.project_slug
		WHERE p.tenant_id = $1
		ORDER BY p.is_default DESC, p.name, p.project_slug, r.is_primary DESC, r.repo_slug`, []any{tenant}, func(rows pgx.Rows) error {
		var p ReleaseProject
		var r ReleaseProjectRepo
		if err := rows.Scan(&p.Slug, &p.Name, &p.IsDefault, &r.Slug, &r.WebURL, &r.CommitPath, &r.TrunkBranch,
			&r.SyncStatus, &r.LastSyncedAt, &r.IsPrimary, &r.NotesPublic); err != nil {
			return err
		}
		if r.LastSyncedAt != nil {
			at := r.LastSyncedAt.UTC()
			r.LastSyncedAt = &at
		}
		if n := len(out); n > 0 && out[n-1].Slug == p.Slug {
			out[n-1].Repos = append(out[n-1].Repos, r)
			return nil
		}
		p.Repos = []ReleaseProjectRepo{r}
		out = append(out, p)
		return nil
	})
	return out, err
}

// SoftwareProjects is the operator's write of a workspace's projects
// (section 4.5): only the operator registers, never a workspace admin.
type SoftwareProjects interface {
	// PutSoftwareProject creates or renames project slug of tenant, under
	// the operator scope. isDefault moves the default to it; a workspace's
	// first project becomes its default whatever isDefault says, and the
	// default never moves away by a false. Answers whether it is the
	// default after the write.
	PutSoftwareProject(ctx context.Context, tenant, slug, name string, isDefault bool) (bool, error)
}

var (
	_ SoftwareProjects = (*Postgres)(nil)
	_ SoftwareProjects = (*Memory)(nil)
)

// softwareProjectSlugRe is rdb 0266's software_projects project_slug CHECK.
var softwareProjectSlugRe = regexp.MustCompile(`^[a-z0-9][a-z0-9-]{0,47}$`)

// CheckSoftwareProject names the first thing a project write may not carry:
// the Go side of rdb 0266's CHECKs, so the route refuses with a 400.
func CheckSoftwareProject(tenant, slug, name string) error {
	switch {
	case checkTenant(tenant) != nil:
		return ErrNoTenant
	case !softwareProjectSlugRe.MatchString(slug):
		return errors.New("project must be 1..48 lowercase letters, digits or -, starting with a letter or digit")
	case utf8.RuneCountInString(name) < 1 || utf8.RuneCountInString(name) > 120 || hasControl(name):
		return errors.New("name must be one line of 1..120 characters")
	}
	return nil
}

// PutSoftwareProject is SoftwareProjects on Postgres: one operator-scope
// transaction, serialised per workspace so two writes never both take the
// default.
func (s *Postgres) PutSoftwareProject(ctx context.Context, tenant, slug, name string, isDefault bool) (bool, error) {
	if err := CheckSoftwareProject(tenant, slug, name); err != nil {
		return false, err
	}
	var def bool
	err := s.asOperator(ctx, func(tx pgx.Tx) error {
		if _, err := tx.Exec(ctx, `SELECT pg_advisory_xact_lock(hashtext('software_projects:' || $1))`, tenant); err != nil {
			return err
		}
		var other bool
		if err := tx.QueryRow(ctx, `SELECT EXISTS (SELECT 1 FROM software_projects
			WHERE tenant_id = $1 AND is_default AND project_slug <> $2)`, tenant, slug).Scan(&other); err != nil {
			return err
		}
		def = isDefault || !other
		if isDefault && other {
			if _, err := tx.Exec(ctx, `UPDATE software_projects SET is_default = false, updated_at = now()
				WHERE tenant_id = $1 AND is_default AND project_slug <> $2`, tenant, slug); err != nil {
				return err
			}
		}
		_, err := tx.Exec(ctx, `INSERT INTO software_projects (tenant_id, project_slug, name, is_default)
			VALUES ($1, $2, $3, $4)
			ON CONFLICT (tenant_id, project_slug) DO UPDATE SET name = EXCLUDED.name,
				is_default = EXCLUDED.is_default, updated_at = now()`, tenant, slug, name, def)
		return err
	})
	return def, err
}

// Memory side: a per-store map beside the Memory struct, as memRepos.
type memProject struct {
	ReleaseProject
	primary string
}

var (
	memProjectMu sync.Mutex
	memProjects  = map[*Memory]map[string]map[string]*memProject{}
)

// SeedProjectRepo registers repo under project of tenant on the memory
// store, which has no registration route, creating the project on first
// use. isDefault and name apply when the project is created; primary marks
// the repo listed first and sets its IsPrimary. It does not touch
// WorkspaceRepo's registry (SeedWorkspaceRepo).
func (s *Memory) SeedProjectRepo(tenant, project, name string, isDefault bool, repo ReleaseProjectRepo, primary bool) {
	memProjectMu.Lock()
	defer memProjectMu.Unlock()
	if memProjects[s] == nil {
		memProjects[s] = map[string]map[string]*memProject{}
	}
	if memProjects[s][tenant] == nil {
		memProjects[s][tenant] = map[string]*memProject{}
	}
	p := memProjects[s][tenant][project]
	if p == nil {
		p = &memProject{ReleaseProject: ReleaseProject{Slug: project, Name: name, IsDefault: isDefault}}
		memProjects[s][tenant][project] = p
	}
	repo.IsPrimary = primary
	p.Repos = append(p.Repos, repo)
	if primary {
		p.primary = repo.Slug
	}
}

// PutSoftwareProject is SoftwareProjects on the memory store, the Postgres rules.
func (s *Memory) PutSoftwareProject(_ context.Context, tenant, slug, name string, isDefault bool) (bool, error) {
	if err := CheckSoftwareProject(tenant, slug, name); err != nil {
		return false, err
	}
	memProjectMu.Lock()
	defer memProjectMu.Unlock()
	if memProjects[s] == nil {
		memProjects[s] = map[string]map[string]*memProject{}
	}
	ps := memProjects[s][tenant]
	if ps == nil {
		ps = map[string]*memProject{}
		memProjects[s][tenant] = ps
	}
	other := false
	for k, p := range ps {
		other = other || (k != slug && p.IsDefault)
	}
	def := isDefault || !other
	for k, p := range ps {
		if isDefault && k != slug {
			p.IsDefault = false
		}
	}
	p := ps[slug]
	if p == nil {
		p = &memProject{ReleaseProject: ReleaseProject{Slug: slug}}
		ps[slug] = p
	}
	p.Name, p.IsDefault = name, def
	return def, nil
}

// ReleaseProjects is ReleaseReports.ReleaseProjects on the memory store, in
// the Postgres order.
func (s *Memory) ReleaseProjects(_ context.Context, tenant string) ([]ReleaseProject, error) {
	if err := checkTenant(tenant); err != nil {
		return nil, err
	}
	memProjectMu.Lock()
	defer memProjectMu.Unlock()
	out := []ReleaseProject{}
	for _, p := range memProjects[s][tenant] {
		if len(p.Repos) == 0 {
			continue
		}
		cp := p.ReleaseProject
		cp.Repos = slices.Clone(p.Repos)
		slices.SortFunc(cp.Repos, func(a, b ReleaseProjectRepo) int {
			return cmp.Or(-cmp.Compare(boolInt(a.Slug == p.primary), boolInt(b.Slug == p.primary)), cmp.Compare(a.Slug, b.Slug))
		})
		out = append(out, cp)
	}
	slices.SortFunc(out, func(a, b ReleaseProject) int {
		return cmp.Or(-cmp.Compare(boolInt(a.IsDefault), boolInt(b.IsDefault)), cmp.Compare(a.Name, b.Name), cmp.Compare(a.Slug, b.Slug))
	})
	return out, nil
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

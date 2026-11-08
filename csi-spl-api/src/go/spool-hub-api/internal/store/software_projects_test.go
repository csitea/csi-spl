package store

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/jackc/pgx/v5"
	"github.com/jackc/pgx/v5/pgconn"
)

// Spec 143 releases-projects row B-1 (rdb 0266, 0267, SPL-4983). Postgres only
// (hub-pg.tst.sh). Each test is red before its migration: the table or column
// it reads does not exist.

// sqlFileGlob is one migration's text, found by name so a renumber at push
// time changes no test.
func sqlFileGlob(t *testing.T, suffix string) string {
	t.Helper()
	hits, err := filepath.Glob(filepath.Join(sqlDir(t), "*_"+suffix))
	if err != nil || len(hits) != 1 {
		t.Fatalf("migration %s: %v, %v", suffix, hits, err)
	}
	raw, err := os.ReadFile(hits[0])
	if err != nil {
		t.Fatal(err)
	}
	return string(raw)
}

// sqlRefusal is a statement's SQLSTATE/constraint, "" when it was stored. The
// constraint is empty for an RLS refusal, so that form is SQLSTATE alone.
func sqlRefusal(t *testing.T, err error) string {
	t.Helper()
	if err == nil {
		return ""
	}
	var pe *pgconn.PgError
	if !errors.As(err, &pe) {
		t.Fatal(err)
	}
	return pe.Code + "/" + pe.ConstraintName
}

// putProject and putRepo write as the operator, the only scope that may.
func putProject(pg *Postgres, tenant, slug string, isDefault bool) error {
	return pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), `INSERT INTO software_projects (tenant_id, project_slug, name, is_default)
			VALUES ($1, $2, $2, $3)`, tenant, slug, isDefault)
		return err
	})
}

func putRepo(pg *Postgres, tenant, project, slug string, primary bool) error {
	return pg.asOperator(context.Background(), func(tx pgx.Tx) error {
		_, err := tx.Exec(context.Background(), `INSERT INTO workspace_repos (tenant_id, repo_slug, project_slug, is_primary, repo_web_url)
			VALUES ($1, $2, $3, $4, 'https://example.com/repo')`, tenant, slug, project, primary)
		return err
	})
}

// GATE: many projects and repos per workspace, one default, one primary.
// RED CONTROLS (row B-1): a second default project in one workspace, and one
// repo slug in two workspaces, each fail on their unique index.
func TestSoftwareProjectsUniqueIndexes(t *testing.T) {
	pg := rlsStore(t)
	a, b := newTenant(t, pg), newTenant(t, pg)
	slug := "csitea/once-" + a
	for _, w := range []struct {
		name string
		err  error
		want string
	}{
		{"first project", putProject(pg, a, "web-shop", true), ""},
		{"second project, not default", putProject(pg, a, "web-admin", false), ""},
		{"second default", putProject(pg, a, "web-other", true), "23505/software_projects_one_default"},
		{"the default of another workspace", putProject(pg, b, "web-shop", true), ""},
		{"first repo", putRepo(pg, a, "web-shop", slug, true), ""},
		{"second repo, not primary", putRepo(pg, a, "web-shop", slug+"-wui", false), ""},
		{"a repo of the second project", putRepo(pg, a, "web-admin", slug+"-admin", false), ""},
		{"second primary", putRepo(pg, a, "web-shop", slug+"-api", true), "23505/workspace_repos_one_primary_idx"},
		{"one slug in two workspaces, primary", putRepo(pg, b, "web-shop", slug, true), "23505/workspace_repos_slug_once"},
		{"one slug in two workspaces, not primary", putRepo(pg, b, "web-shop", slug+"-wui", false), "23505/workspace_repos_slug_once"},
		{"a project the workspace does not have", putRepo(pg, a, "nope", slug+"-x", false), "23503/workspace_repos_project_fk"},
		{"another workspace's project", putRepo(pg, b, "web-admin", slug+"-y", false), "23503/workspace_repos_project_fk"},
		{"a slug in upper case", putRepo(pg, a, "web-shop", "Csitea/UP-"+a, false), "23514/workspace_repos_slug_chk"},
		{"a project slug in upper case", putProject(pg, a, "Web", false), "23514/software_projects_project_slug_check"},
	} {
		if got := sqlRefusal(t, w.err); got != w.want {
			t.Errorf("%s: got %q, want %q", w.name, got, w.want)
		}
	}
}

// GATE (4.3, row B-1): deleting a workspace with a project and a repo succeeds
// and takes both, and deleting one project takes that project's repos. RED
// CONTROLS: the other workspace's rows and the other project's repo stay. The
// project delete is what tells CASCADE from NO ACTION: on a workspace delete
// the tenants cascade has emptied the repos before a NO ACTION check runs.
func TestSoftwareProjectsWorkspaceDelete(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	gone, kept := newTenant(t, pg), newTenant(t, pg)
	for _, tn := range []string{gone, kept} {
		if err := putProject(pg, tn, "web-shop", true); err != nil {
			t.Fatal(err)
		}
		if err := putRepo(pg, tn, "web-shop", "csitea/del-"+tn, true); err != nil {
			t.Fatal(err)
		}
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM tenants WHERE tenant_id = $1`, gone)
		return err
	}); err != nil {
		t.Fatalf("delete a workspace with a project and a repo: %v", err)
	}
	for tn, want := range map[string]int{gone: 0, kept: 1} {
		for _, tb := range []string{"software_projects", "workspace_repos"} {
			if got := countOf(t, pg, tb, tn); got != want {
				t.Errorf("%s of %s: %d rows, want %d", tb, tn, got, want)
			}
		}
	}
	if err := putProject(pg, kept, "web-admin", false); err != nil {
		t.Fatal(err)
	}
	if err := putRepo(pg, kept, "web-admin", "csitea/del-admin-"+kept, false); err != nil {
		t.Fatal(err)
	}
	if err := pg.asOperator(ctx, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `DELETE FROM software_projects WHERE tenant_id = $1 AND project_slug = 'web-admin'`, kept)
		return err
	}); err != nil {
		t.Fatalf("delete a project with a repo: %v", err)
	}
	if got := countOf(t, pg, "workspace_repos", kept); got != 1 {
		t.Errorf("after the project delete, %d repos, want the other project's 1", got)
	}
}

// GATE: a member reads the workspace's rows and no other's; no tenant scope
// writes. RED CONTROL: with no scope a statement reads nothing.
func TestSoftwareProjectsRowSecurity(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	a, b := newTenant(t, pg), newTenant(t, pg)
	for _, tn := range []string{a, b} {
		if err := putProject(pg, tn, "web-shop", true); err != nil {
			t.Fatal(err)
		}
		if err := putRepo(pg, tn, "web-shop", "csitea/rls-"+tn, true); err != nil {
			t.Fatal(err)
		}
	}
	for _, tb := range []string{"software_projects", "workspace_repos"} {
		var own, other int
		if err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FILTER (WHERE tenant_id = $1), count(*) FILTER (WHERE tenant_id <> $1)
				FROM `+pgx.Identifier{tb}.Sanitize(), a).Scan(&own, &other)
		}); err != nil {
			t.Fatal(err)
		}
		if own != 1 || other != 0 {
			t.Errorf("%s in A's scope: own %d (want 1), other %d (want 0)", tb, own, other)
		}
		var bare int
		if err := pgx.BeginFunc(ctx, pg.pool, func(tx pgx.Tx) error {
			return tx.QueryRow(ctx, `SELECT count(*) FROM `+pgx.Identifier{tb}.Sanitize()).Scan(&bare)
		}); err != nil {
			t.Fatal(err)
		}
		if bare != 0 {
			t.Errorf("%s with no scope reads %d rows, want 0", tb, bare)
		}
	}
	err := pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO software_projects (tenant_id, project_slug, name) VALUES ($1, 'mine', 'Mine')`, a)
		return err
	})
	if got := sqlRefusal(t, err); !strings.HasPrefix(got, "42501/") {
		t.Errorf("a tenant-scoped project insert: %q, want 42501", got)
	}
	err = pg.inTenant(ctx, a, func(tx pgx.Tx) error {
		_, err := tx.Exec(ctx, `INSERT INTO workspace_repos (tenant_id, repo_slug, project_slug, repo_web_url)
			VALUES ($1, $2, 'web-shop', 'https://example.com/repo')`, a, "csitea/self-"+a)
		return err
	})
	if got := sqlRefusal(t, err); !strings.HasPrefix(got, "42501/") {
		t.Errorf("a tenant-scoped repo insert: %q, want 42501", got)
	}
}

// GATE (4.4): the seed writes t1's project and repo as the section names them,
// and is a no-op on a database with no t1. Run in one transaction that rolls
// back: the file is applied to freshly dropped tables, with and without t1.
func TestSoftwareProjectsSeed(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	raw := sqlFileGlob(t, "software_projects_workspace_repos.sql")
	tx, err := pg.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	exec := func(what, q string, args ...any) {
		t.Helper()
		if _, err := tx.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", what, err)
		}
	}
	reapply := func() (projects, repos int) {
		t.Helper()
		exec("drop", `DROP TABLE workspace_repos; DROP TABLE software_projects`)
		exec("apply", raw)
		if err := tx.QueryRow(ctx, `SELECT (SELECT count(*) FROM software_projects), (SELECT count(*) FROM workspace_repos)`).Scan(&projects, &repos); err != nil {
			t.Fatal(err)
		}
		return projects, repos
	}
	exec("operator", `SELECT set_config('app.rls_scope', 'operator', true)`)
	exec("no t1", `DELETE FROM tenants WHERE tenant_id = 't1'`)
	if p, r := reapply(); p != 0 || r != 0 {
		t.Errorf("no t1: %d projects, %d repos, want none", p, r)
	}
	exec("t1", `INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('t1', $1)`, []byte(pubkey()))
	if p, r := reapply(); p != 1 || r != 1 {
		t.Fatalf("with t1: %d projects, %d repos, want 1 and 1", p, r)
	}
	var project, name, repo, repoProject, webURL, trunk, strip string
	var isDefault, primary, public bool
	if err := tx.QueryRow(ctx, `SELECT p.project_slug, p.name, p.is_default, r.repo_slug, r.project_slug, r.is_primary, r.notes_public,
			r.repo_web_url, r.trunk_branch, r.area_strip_prefix
		FROM software_projects p JOIN workspace_repos r USING (tenant_id) WHERE p.tenant_id = 't1'`).Scan(
		&project, &name, &isDefault, &repo, &repoProject, &primary, &public, &webURL, &trunk, &strip); err != nil {
		t.Fatal(err)
	}
	if project != "csi-spl" || !isDefault || repo != "csitea/csi-spl" || repoProject != "csi-spl" || !primary || !public {
		t.Errorf("t1's seed: project %q default %v, repo %q of %q primary %v public %v", project, isDefault, repo, repoProject, primary, public)
	}
	if name != "csi-spl" || webURL != "https://github.com/csitea/csi-spl" || trunk != "master" || strip != "csi-spl-" {
		t.Errorf("t1's seed: name %q, url %q, trunk %q, strip %q", name, webURL, trunk, strip)
	}
}

// expandBefore undoes rdb 0267 on the tables in a rolled-back transaction, the
// state a live database is in when the file applies. DROP COLUMN takes the new
// indexes with it; the old version CHECKs come back as 0114 and 0202 wrote them.
// The first UPDATE keeps 0267's own off the rows other tests committed in tags
// the old CHECK refuses, which NOT VALID still enforces on an update.
const expandBefore = `UPDATE release_notes SET issue_tenant = 't1' WHERE issue_tenant IS NULL;
ALTER TABLE release_notes DROP COLUMN tenant_id, DROP COLUMN repo_slug, DROP COLUMN body;
ALTER TABLE release_notes DROP CONSTRAINT release_notes_version_check;
ALTER TABLE release_notes ADD CONSTRAINT release_notes_version_check
    CHECK (version ~ '^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c([2-9]|[1-9][0-9]{1,3}))?$') NOT VALID;
ALTER TABLE estate_deploys DROP COLUMN tenant_id, DROP COLUMN repo_slug`

// GATE (spec 171 Step A with 4.3), one transaction that rolls back: rows of the
// old shape survive and land on t1's one repo, the old hub's insert and upsert
// still run, tags of another repo's shape store, the old hub's list keeps rdb
// 0114's key index, and row B-3's key swap is possible. RED CONTROLS: a body
// over 2000, a tag no shape admits and a bad component are each refused. Row
// B-2's migration rebuilt that index guarded, so 'v1.2.' stores.
func TestReleaseNotesDeploysExpand(t *testing.T) {
	pg := rlsStore(t)
	ctx := context.Background()
	raw := sqlFileGlob(t, "release_notes_deploys_expand.sql")
	tx, err := pg.pool.Begin(ctx)
	if err != nil {
		t.Fatal(err)
	}
	defer tx.Rollback(ctx) //nolint:errcheck
	exec := func(what, q string, args ...any) {
		t.Helper()
		if _, err := tx.Exec(ctx, q, args...); err != nil {
			t.Fatalf("%s: %v", what, err)
		}
	}
	// try runs under a savepoint so a refusal leaves the transaction usable.
	try := func(q string, args ...any) string {
		t.Helper()
		sp, err := tx.Begin(ctx)
		if err != nil {
			t.Fatal(err)
		}
		defer sp.Rollback(ctx) //nolint:errcheck
		if _, err := sp.Exec(ctx, q, args...); err != nil {
			return sqlRefusal(t, err)
		}
		if err := sp.Commit(ctx); err != nil {
			t.Fatal(err)
		}
		return ""
	}
	const note = `INSERT INTO release_notes (sha, version, committed_at, subject, state) VALUES ($1, $2, now(), 's', 'ok')`
	const deploy = `INSERT INTO estate_deploys (deploy_id, env, component, version, commit_sha, status) VALUES ($1, 'prd', $2, $3, $4, 'success')`

	exec("operator", `SELECT set_config('app.rls_scope', 'operator', true)`)
	exec("before", expandBefore)
	old, oldDeploy := randSHA(), uuid4()
	exec("old note", note, old, "v1.7.1")
	exec("old deploy", deploy, oldDeploy, "hub", "v1.7.1", old)
	exec("after", raw)

	var tenant, repo, issueTenant, body string
	if err := tx.QueryRow(ctx, `SELECT tenant_id, repo_slug, coalesce(issue_tenant, ''), body FROM release_notes WHERE sha = $1`, old).Scan(&tenant, &repo, &issueTenant, &body); err != nil {
		t.Fatal(err)
	}
	if tenant != "t1" || repo != "csitea/csi-spl" || issueTenant != "t1" || body != "" {
		t.Errorf("the old note after expand: tenant %q repo %q issue_tenant %q body %q", tenant, repo, issueTenant, body)
	}
	if err := tx.QueryRow(ctx, `SELECT tenant_id, repo_slug FROM estate_deploys WHERE deploy_id = $1`, oldDeploy).Scan(&tenant, &repo); err != nil {
		t.Fatal(err)
	}
	if tenant != "t1" || repo != "csitea/csi-spl" {
		t.Errorf("the old deploy after expand: tenant %q repo %q", tenant, repo)
	}

	// The running hub's own writes, naming neither new column.
	if got := try(note+` ON CONFLICT (sha) DO UPDATE SET subject = EXCLUDED.subject`, old, "v1.7.1"); got != "" {
		t.Errorf("the old hub's upsert: %s", got)
	}
	if got := try(`INSERT INTO release_notes (sha, tenant_id, repo_slug, committed_at, subject, state) VALUES ($1, 't1', 'csitea/csi-spl', now(), 's', 'ok')
		ON CONFLICT (tenant_id, repo_slug, sha) DO NOTHING`, old); got != "" {
		t.Errorf("the new key's upsert: %s", got)
	}

	for _, w := range []struct{ version, want string }{
		{"v1.2.", ""}, {"2026.11.05", ""}, {"v8.2.6-c3", ""}, {"v0.4.2-beta.1", ""},
		{"v1.0.0-cool", ""}, {"-v1", "23514/release_notes_version_check"},
		{"v 1", "23514/release_notes_version_check"}, {strings.Repeat("v", 65), "23514/release_notes_version_check"},
	} {
		if got := try(note, randSHA(), w.version); got != w.want {
			t.Errorf("tag %q: got %q, want %q", w.version, got, w.want)
		}
	}
	for _, w := range []struct{ component, version, want string }{
		{"web", "2026.11.05", ""}, {"hub", "v1.7.1", ""}, {"site", "", ""},
		{"Web", "v1.0.0", "23514/estate_deploys_component_check"},
		{"web", "-v1", "23514/estate_deploys_version_check"},
	} {
		if got := try(deploy, uuid4(), w.component, w.version, randSHA()); got != w.want {
			t.Errorf("deploy %q %q: got %q, want %q", w.component, w.version, got, w.want)
		}
	}
	if got := try(`UPDATE release_notes SET body = $1 WHERE sha = $2`, strings.Repeat("b", 2000), old); got != "" {
		t.Errorf("a body of 2000: %s", got)
	}
	if got := try(`UPDATE release_notes SET body = $1 WHERE sha = $2`, strings.Repeat("b", 2001), old); got != "23514/release_notes_body_check" {
		t.Errorf("a body of 2001: %q", got)
	}
	// Row B-3's swap: refused on an index that belongs to a constraint.
	if got := try(`ALTER TABLE release_notes DROP CONSTRAINT release_notes_pkey,
		ADD PRIMARY KEY USING INDEX release_notes_tenant_repo_sha`); got != "" {
		t.Errorf("row B-3's key swap: %s", got)
	}
}

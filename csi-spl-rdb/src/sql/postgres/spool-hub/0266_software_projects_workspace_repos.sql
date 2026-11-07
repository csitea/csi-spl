-- 0266_software_projects_workspace_repos.sql - the software projects of a
-- workspace and their repos (spec 143 releases-projects.md v0.2.0 sections
-- 4.2 to 4.4, build row B-1, SPL-4983; spec 171 section 3.2 as those amend
-- it). Forward-only, additive.
--
-- Owner HUM-10, msg 8262d099: "each workspace might have 1 or many software
-- projects and each software project might have one or many repos"; msg
-- 24e35756: "several repos per workspace, grouped by project, one primary
-- repo for chat commit links" and "t1 only, and each repo in exactly one
-- workspace".
--
--   software_projects  one row per project; slug = the URL value, never
--                      changes. At most one default per workspace.
--   workspace_repos    one row per repo. Its project FK cascades because both
--                      tables also cascade from tenants: a workspace delete
--                      succeeds whichever path runs first. The index
--                      workspace_repos_slug_once holds "each repo in exactly
--                      one workspace".
--
-- Members read their workspace's rows; only the operator scope writes
-- (tenantReadOnlyTables, the shape of 0212's tenant_agent_caps). Neither table
-- holds a secret column, so the Reporting SQL tab admits both for an admin's
-- own workspace (a recorded choice: section 4.3).
--
-- The seed is the one mapping that ships in git (spec 171 section 3.2), and a
-- no-op on a database with no t1. Migrate runs in the operator scope; the
-- set_config keeps the seed right when this file is run directly.
-- Live-data safety: two new tables and their seed; no running hub reads them.
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql.

CREATE TABLE software_projects (
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    project_slug text        NOT NULL CHECK (project_slug ~ '^[a-z0-9][a-z0-9-]{0,47}$'),
    name         text        NOT NULL CHECK (length(name) BETWEEN 1 AND 120),
    is_default   boolean     NOT NULL DEFAULT false,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, project_slug)
);

CREATE UNIQUE INDEX software_projects_one_default ON software_projects (tenant_id) WHERE is_default;

ALTER TABLE software_projects ENABLE ROW LEVEL SECURITY;
ALTER TABLE software_projects FORCE ROW LEVEL SECURITY;
CREATE POLICY software_projects_tenant_read ON software_projects
    FOR SELECT
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON software_projects
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

CREATE TABLE workspace_repos (
    tenant_id              text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    repo_slug              text        NOT NULL,
    project_slug           text        NOT NULL,
    is_primary             boolean     NOT NULL DEFAULT true,
    notes_public           boolean     NOT NULL DEFAULT false,
    provider               text        NOT NULL DEFAULT 'github'
                           CHECK (provider IN ('github', 'gitlab', 'gitea', 'other')),
    repo_web_url           text        NOT NULL,
    repo_commit_path       text        NOT NULL DEFAULT '/commit/',
    trunk_branch           text        NOT NULL DEFAULT 'main',
    live_url               text        NOT NULL DEFAULT '',
    version_tag_glob       text        NOT NULL DEFAULT 'v*',
    area_strip_prefix      text        NOT NULL DEFAULT '',
    auth_mode              text        NOT NULL DEFAULT 'github_app'
                           CHECK (auth_mode IN ('github_app', 'pat_kms', 'public', 'ingest_only')),
    github_installation_id bigint      NULL,
    last_synced_sha        text        NULL,
    last_synced_at         timestamptz NULL,
    sync_status            text        NOT NULL DEFAULT 'pending'
                           CHECK (sync_status IN ('pending', 'ok', 'error', 'disabled')),
    sync_error             text        NOT NULL DEFAULT '',
    created_at             timestamptz NOT NULL DEFAULT now(),
    updated_at             timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, repo_slug),
    CONSTRAINT workspace_repos_slug_chk CHECK (repo_slug ~ '^[a-z0-9._-]+/[a-z0-9._-]+$'),
    CONSTRAINT workspace_repos_project_fk FOREIGN KEY (tenant_id, project_slug)
        REFERENCES software_projects (tenant_id, project_slug) ON DELETE CASCADE
);

CREATE UNIQUE INDEX workspace_repos_one_primary_idx ON workspace_repos (tenant_id) WHERE is_primary;
CREATE UNIQUE INDEX workspace_repos_slug_once ON workspace_repos (repo_slug);

ALTER TABLE workspace_repos ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_repos FORCE ROW LEVEL SECURITY;
CREATE POLICY workspace_repos_tenant_read ON workspace_repos
    FOR SELECT
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON workspace_repos
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

SELECT set_config('app.rls_scope', 'operator', true);
INSERT INTO software_projects (tenant_id, project_slug, name, is_default)
SELECT tenant_id, 'csi-spl', 'csi-spl', true
FROM tenants WHERE tenant_id = 't1'
ON CONFLICT DO NOTHING;
INSERT INTO workspace_repos (
    tenant_id, repo_slug, project_slug, is_primary, notes_public, provider, repo_web_url,
    repo_commit_path, trunk_branch, area_strip_prefix, auth_mode
)
SELECT
    tenant_id, 'csitea/csi-spl', 'csi-spl', true, true, 'github', 'https://github.com/csitea/csi-spl',
    '/commit/', 'master', 'csi-spl-', 'github_app'
FROM tenants WHERE tenant_id = 't1'
ON CONFLICT DO NOTHING;

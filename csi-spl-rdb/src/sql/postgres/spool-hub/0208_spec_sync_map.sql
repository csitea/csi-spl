-- 0208_spec_sync_map.sql — the GitSpec / issue / Qto sync ledger (spec 145
-- section 5.2, T002, SPL-2452). Forward-only.
--
-- One row per (tenant, spec file, task row): which issue and which Qto doc
-- and item track it, the git sha of its last export and its sync state. It
-- keeps the UUIDs out of the git .md files. spec_task_id empty string = the
-- whole spec (a level-1 epic, or the spec's Qto doc itself).
--
-- The issue and Qto links are optional, and a deleted issue or doc only
-- clears its own column: ON DELETE SET NULL (issue_number) / (qto_doc_id)
-- names the column, since a bare SET NULL would also null tenant_id, which
-- is NOT NULL (spec 5.2 sketch fixed here). qto_item_id has no FK: an item
-- id lives per doc revision (spec 5.1) and the T041/T031 writers own it.
--
-- RLS: the 0021 fail-closed form (NULLIF) plus the operator policy. No
-- writer yet (T031, T041), so the running image never reads it.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS spec_sync_map (
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    spec_path    text        NOT NULL
                 CHECK (spec_path ~ '^csi-spl-doc/specs/[0-9]{3}-[a-z0-9_-]+/[a-z0-9_.-]+\.md$' AND length(spec_path) <= 255),
    spec_task_id text        NOT NULL DEFAULT ''
                 CHECK (length(spec_task_id) <= 32 AND (spec_task_id = '' OR spec_task_id ~ '^[A-Za-z0-9_.-]+$')),
    issue_number integer     NULL,
    qto_doc_id   uuid        NULL,
    qto_item_id  uuid        NULL,
    last_git_sha text        NOT NULL DEFAULT '' CHECK (last_git_sha = '' OR last_git_sha ~ '^[0-9a-f]{40}$'),
    last_sync_at timestamptz NOT NULL DEFAULT now(),
    sync_status  text        NOT NULL DEFAULT 'in_sync'
                 CHECK (sync_status IN ('in_sync', 'pending_export', 'pending_import', 'conflict')),
    PRIMARY KEY (tenant_id, spec_path, spec_task_id),
    FOREIGN KEY (tenant_id, issue_number) REFERENCES issues (tenant_id, number) ON DELETE SET NULL (issue_number),
    FOREIGN KEY (tenant_id, qto_doc_id) REFERENCES workspace_doc (tenant_id, id) ON DELETE SET NULL (qto_doc_id)
);
-- Issue -> its spec rows, and doc -> its spec rows (the FK actions use them too).
CREATE INDEX IF NOT EXISTS spec_sync_map_issue ON spec_sync_map (tenant_id, issue_number) WHERE issue_number IS NOT NULL;
CREATE INDEX IF NOT EXISTS spec_sync_map_doc ON spec_sync_map (tenant_id, qto_doc_id) WHERE qto_doc_id IS NOT NULL;

ALTER TABLE spec_sync_map ENABLE ROW LEVEL SECURITY;
ALTER TABLE spec_sync_map FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON spec_sync_map
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON spec_sync_map
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

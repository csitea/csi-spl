-- 0115_operator_workspaces.sql - workspace CRUD by the operator workspace
-- (spec 074 phase 1, owner HUM-10 t1 aa35699c: "only the admin of the
-- spool-hub could perform any spool-hub instance specific changes, like add
-- or remove tenants"). Forward-only.
--
--   tenants.suspended_at  the instant an operator suspended the workspace.
--                         NULL = live (every workspace before this file).
--                         While set the hub's doors refuse the workspace
--                         (browser and box) with 403 workspace_suspended;
--                         nothing is deleted, resume clears it.
--   tenants.archived_at   the instant an operator archived (soft-deleted)
--                         the workspace: DELETE /v1/operator/workspaces/{id}
--                         sets it together with suspended_at. The rows stay;
--                         a hard purge is not offered by this file.
--
--   operator_audit        one row per operator action (who / what / when /
--                         which workspace). tenant_id is the TARGET
--                         workspace (the operator workspace itself for a
--                         list), with no foreign key, so the trail outlives
--                         the workspace it names. Append-only: the hub only
--                         INSERTs and SELECTs it, in the target's scope.
--
-- Both columns are nullable with no default: a catalog-only ADD COLUMN, no
-- rewrite, and the running image ignores them. DEPLOY ORDER: apply BEFORE
-- the hub that bundles this file - spec 072 A45 makes `spool serve` refuse a
-- database behind its image. (The store still probes the catalogue for the
-- two columns, store/operator_workspaces.go, so a run without the A45 check
-- reads tenants without them and answers 503 not_migrated, never a 500.)
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS suspended_at timestamptz NULL,
    ADD COLUMN IF NOT EXISTS archived_at  timestamptz NULL;

CREATE TABLE operator_audit (
    id           bigserial   PRIMARY KEY,
    at           timestamptz NOT NULL,
    tenant_id    text        NOT NULL,
    actor_tenant text        NOT NULL,
    actor_hum    text        NOT NULL,
    action       text        NOT NULL CHECK (action IN ('list', 'read', 'create', 'update', 'suspend', 'resume', 'archive')),
    detail       jsonb       NOT NULL DEFAULT '{}'::jsonb
);
-- One workspace's trail, oldest first.
CREATE INDEX operator_audit_tenant_at ON operator_audit (tenant_id, at);

-- RLS in the 0106 shape, with the empty-setting guard (NULLIF).
ALTER TABLE operator_audit ENABLE ROW LEVEL SECURITY;
ALTER TABLE operator_audit FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON operator_audit
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON operator_audit
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

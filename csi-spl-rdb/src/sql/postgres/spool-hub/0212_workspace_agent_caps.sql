-- 0212_workspace_agent_caps.sql — per-workspace agent caps by vendor
-- (spec 147 R1, SPL-2675; owner HUM-10 t1 4ce4c8db msg 9c96ca9e: "the
-- spool-hub admin should be able to define a max amount of agents and their
-- kind per workspace"). Forward-only, additive, idempotent.
--
--   tenant_agent_caps  one row per capped (workspace, vendor): at most
--                      max_live concurrent live agents of that vendor
--                      (store.vendorCapGate in SetRoster). No row = that
--                      vendor is uncapped; max_live = 0 forbids it.
--
-- Read in the workspace's own scope (members see their caps, and SetRoster
-- reads them in its tenant transaction); written ONLY in the operator scope
-- (the spool-hub admin's routes, spec 147 section 6.1): the tenant_scope
-- policy is FOR SELECT, so a tenant-scoped INSERT / UPDATE / DELETE is
-- refused by RLS, whatever the route.
--
-- operator_audit.action gains set_agent_caps and delete_agent_cap (spec 147
-- section 3.2): the CHECK of rdb 0115 is replaced by a wider one.
--
-- DEPLOY ORDER: apply this file BEFORE the hub that bundles it. The store
-- still probes the catalogue for the table (store/agent_caps_postgres.go),
-- so a hub on a database without it seats everyone, as before.
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS tenant_agent_caps (
    tenant_id   text        NOT NULL,
    vendor      text        NOT NULL,
    max_live    integer     NOT NULL,
    created_at  timestamptz NOT NULL DEFAULT now(),
    updated_at  timestamptz NOT NULL DEFAULT now(),
    updated_by  text        NOT NULL,
    CONSTRAINT pk_tenant_agent_caps PRIMARY KEY (tenant_id, vendor),
    CONSTRAINT fk_tenant_agent_caps_tenant FOREIGN KEY (tenant_id)
        REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    CONSTRAINT chk_tenant_agent_caps_vendor
        CHECK (vendor IN ('claude', 'grok', 'mistral', 'agy', 'qwen')),
    CONSTRAINT chk_tenant_agent_caps_max_live
        CHECK (max_live >= 0)
);
-- No index on tenant_id: it leads the primary key.

-- RLS, fail-closed (NULLIF): the workspace reads, only the operator writes.
ALTER TABLE tenant_agent_caps ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_agent_caps FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON tenant_agent_caps;
CREATE POLICY tenant_scope ON tenant_agent_caps
    FOR SELECT
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON tenant_agent_caps;
CREATE POLICY operator_scope ON tenant_agent_caps
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE operator_audit DROP CONSTRAINT IF EXISTS operator_audit_action_check;
ALTER TABLE operator_audit ADD CONSTRAINT operator_audit_action_check
    CHECK (action IN ('list', 'read', 'create', 'update', 'suspend', 'resume', 'archive',
                      'set_agent_caps', 'delete_agent_cap'));

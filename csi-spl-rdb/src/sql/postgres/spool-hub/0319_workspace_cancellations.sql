-- 0319_workspace_cancellations.sql - a private workspace's cancel (spec 181
-- row B9, section 4.5, gap G8). Forward-only, additive, idempotent.
--
-- Owner HUM-10, t1 b12055b5, msg 9beaf299, Q-12 C: "The VM is deleted at
-- once; only the hub data stays 30 days". The operator cancel
-- (POST /v1/operator/workspaces/{id}/cancel, store CancelWorkspace) writes,
-- in one operator transaction, this row, the revoke of every live pin and
-- open join token of the workspace (spec 108 3.7), box_join_enabled off and
-- one operator_audit row (cancel_workspace). From then on a vendor key lease
-- of the workspace is 403 workspace_cancelled. The hub's purge tick deletes
-- the workspace (DELETE FROM tenants, every ON DELETE CASCADE table) once
-- purge_after has passed, sets purged_at and writes one operator_audit row
-- (purge_workspace). The VM delete is the orc action's, on the owner's go.
--
-- No FK to tenants, on purpose: the row is the tombstone that outlives the
-- purge (what was cancelled, when, by whom, when it was purged), like
-- operator_audit (rdb 0115, no FK either). It holds ids and times only.
--
-- RLS: the 0212 shape. A workspace reads its own row (the lease check runs
-- in its tenant scope); only the operator scope writes. store
-- TestRLSPoliciesFailClosed reads it from the catalogue and
-- TestCrossTenantEveryTable seeds it (crosstenant_test.go, a tenant
-- read-only table).
--
-- Live-data safety: one new empty table; the operator_audit CHECK is
-- replaced by one wider by two actions, so every stored row passes it.
-- DEPLOY ORDER: apply BEFORE the hub that writes the new actions (wf 20 does).

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS workspace_cancellations (
    tenant_id    text        PRIMARY KEY CHECK (tenant_id <> ''),
    cancelled_at timestamptz NOT NULL,
    purge_after  timestamptz NOT NULL,
    purged_at    timestamptz NULL,
    actor_tenant text        NOT NULL,
    actor_hum    text        NOT NULL,
    CONSTRAINT workspace_cancellations_30_days CHECK (purge_after = cancelled_at + interval '30 days'),
    CONSTRAINT workspace_cancellations_purged_after CHECK (purged_at IS NULL OR purged_at >= purge_after)
);

CREATE INDEX IF NOT EXISTS workspace_cancellations_due
    ON workspace_cancellations (purge_after) WHERE purged_at IS NULL;

ALTER TABLE workspace_cancellations ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_cancellations FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON workspace_cancellations;
CREATE POLICY tenant_scope ON workspace_cancellations
    FOR SELECT
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON workspace_cancellations;
CREATE POLICY operator_scope ON workspace_cancellations
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE operator_audit DROP CONSTRAINT IF EXISTS operator_audit_action_check;
ALTER TABLE operator_audit ADD CONSTRAINT operator_audit_action_check
    CHECK (action IN ('list', 'read', 'create', 'update', 'suspend', 'resume', 'archive',
                      'set_agent_caps', 'delete_agent_cap', 'mint_join_token',
                      'cancel_workspace', 'purge_workspace'));

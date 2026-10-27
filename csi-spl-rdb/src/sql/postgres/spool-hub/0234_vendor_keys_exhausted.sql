-- 0234_vendor_keys_exhausted.sql - a workspace key the vendor refused, and
-- the workspace's metered fall-back switch (spec 159 v0.2 section 9 and row
-- T5, with spec 127 v1.4 row H2; SPL-3738). Forward-only, additive.
--
-- 1. workspace_vendor_keys.exhausted_at: set when a box reports that the
--    vendor refused the kind's key for credit, quota or a revoked key (159
--    9, point 2; the box classifies, the report carries no vendor text).
--    While it is set the hub refuses that kind's lease 409 key_exhausted.
--    A replace (PUT) clears it, and so does "retry" on the Agent keys page.
--    NULL = usable.
-- 2. workspace_vendor_key_audit gains the actions 'exhausted' (a box's
--    report: kind and box named), 'retry' (a manager cleared the state:
--    kind named) and 'fallback_on' / 'fallback_off' (the switch of 3.). The
--    audit stays append-only (rdb 0174's trigger).
-- 3. workspace_vendor_key_settings: one row per workspace that ever touched
--    the switch "fall back to spool-hub's metered agents" (159 9, owner Q-2
--    B, msg 45b1e8af). No row = OFF, the default. Only vendor_keys.manage
--    changes it (biz_owner, admin). No secret: tenant_scope + operator_scope,
--    as workspace_vendor_key_boxes.
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014). Live-data
-- safety: one nullable column on workspace_vendor_keys and three CHECKs
-- replaced on workspace_vendor_key_audit (both tables are written only by
-- rdb 0232's routes, which stay off until the KMS key is configured, so the
-- CHECK scans read few rows), one new empty table; ACCESS EXCLUSIVE locks
-- until COMMIT, hence lock_timeout. No personal data, no secret. DEPLOY
-- ORDER: wf 20 applies it before the image that reads it.

SET LOCAL lock_timeout = '5s';

ALTER TABLE workspace_vendor_keys ADD COLUMN exhausted_at timestamptz NULL;

ALTER TABLE workspace_vendor_key_audit
    DROP CONSTRAINT workspace_vendor_key_audit_action_check,
    ADD CONSTRAINT workspace_vendor_key_audit_action_check CHECK (action IN ('set', 'replace', 'remove', 'lease',
        'box_approve', 'box_revoke', 'admin_confirm', 'exhausted', 'retry', 'fallback_on', 'fallback_off')),
    DROP CONSTRAINT workspace_vendor_key_audit_key_kind_check,
    ADD CONSTRAINT workspace_vendor_key_audit_key_kind_check CHECK (
        action NOT IN ('set', 'replace', 'remove', 'lease', 'exhausted', 'retry') OR kind IS NOT NULL),
    DROP CONSTRAINT workspace_vendor_key_audit_box_named_check,
    ADD CONSTRAINT workspace_vendor_key_audit_box_named_check CHECK (
        action NOT IN ('lease', 'box_approve', 'box_revoke', 'exhausted') OR box_id IS NOT NULL);

CREATE TABLE workspace_vendor_key_settings (
    tenant_id        text        PRIMARY KEY REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    metered_fallback boolean     NOT NULL DEFAULT false,
    set_by           text        NOT NULL CHECK (length(set_by) BETWEEN 1 AND 200),
    set_at           timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE workspace_vendor_key_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_vendor_key_settings FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON workspace_vendor_key_settings
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON workspace_vendor_key_settings
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

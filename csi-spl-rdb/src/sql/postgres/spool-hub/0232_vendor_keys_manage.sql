-- 0232_vendor_keys_manage.sql - who may set a workspace's own vendor keys
-- (spec 159 v0.2 section 3 and row T1, with spec 127 v1.4 rows H1, 4.3,
-- 5.1; SPL-3684). Forward-only, additive.
--
-- 1. The permission vendor_keys.manage, granted to biz_owner AND admin. Spec
--    159 section 3 (owner HUM-10, t1 f8f9dfcc, msg 87578f3a) replaces spec
--    127's "admin only". The hub asks it at GET / PUT / DELETE
--    /v1/vendor-keys and PUT /v1/vendor-keys/managers/{human_id}, refuses it
--    under an act-as session, and refuses PUT / DELETE / confirm to an
--    unconfirmed manager (2.). The rows MUST equal internal/rbac Defaults +
--    Permissions (store TestRBACSeedMatchesDefaults).
--
-- 2. workspace_vendor_key_audit.subject: the member an admin_confirm row
--    confirms (a HUM-* id), NULL on every other action. A membership
--    admitted by 'operator' or 'bootstrap' (tenant_memberships.admitted_by,
--    rdb 0006), in a workspace that holds a key, is an UNCONFIRMED manager
--    until a confirmed manager writes an admin_confirm row naming it, at or
--    after the membership's created_at (spec 127 Q-4 A, spec 159 L22): a
--    member removed and re-invited by the operator is unconfirmed again.
--    The audit stays append-only (rdb 0174's trigger), so a confirmation is
--    never edited away; the CHECK pins subject to admin_confirm rows.
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014). Live-data
-- safety: one catalogue row and two grants; one nullable column and two
-- CHECKs on workspace_vendor_key_audit, which no hub before this commit
-- writes (spec 127 H1 is this commit; no route wrote it), so the CHECKs
-- scan no hub row and the ACCESS EXCLUSIVE lock is short (lock_timeout). No
-- personal data, no secret. DEPLOY ORDER: wf 20 applies it before the
-- image that reads it.

SET LOCAL lock_timeout = '5s';

INSERT INTO rbac_permissions (permission_id, description) VALUES
    ('vendor_keys.manage', 'set, replace and remove the workspace''s agent vendor keys; confirm an operator-made manager');

INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES
    ('biz_owner', 'vendor_keys.manage'), ('admin', 'vendor_keys.manage');

ALTER TABLE workspace_vendor_key_audit
    ADD COLUMN subject text NULL
        CONSTRAINT workspace_vendor_key_audit_subject_check CHECK (subject ~ '^HUM-[0-9]+$'),
    ADD CONSTRAINT workspace_vendor_key_audit_confirm_subject_check CHECK (
        (action = 'admin_confirm') = (subject IS NOT NULL));

-- 0074_tenant_settings.sql — the Tenant settings area (SPL-1037, specs/046).
-- Forward-only.
--
-- Owner, 2026-09-28 (prd t1 topic 3b826d0d): "it should have a section for
-- users where the admins and the biz_owners of the tenant can CRUD users".
--
-- 1. tenants.default_locale: the tenant's language, set on Tenant settings ->
--    General. NULL = the hub default. The same 19 locales as
--    humans.preferred_locale (0017); adding a locale replaces both checks.
-- 2. tenant_memberships.disabled_at: disable / enable a member IN THIS
--    TENANT. humans.disabled_at is the whole account across every tenant, and
--    a tenant admin must not reach past their own tenant; a membership with
--    disabled_at set holds no role here (the hub reads it as not a member)
--    and the account keeps its other tenants.
-- 3. members.invite returns to biz_owner (0039 had made it the admin's
--    only). biz_owner then holds every permission, so it may manage every
--    role; an admin still cannot manage a biz_owner (billing.manage).
--
-- The rows MUST equal internal/rbac Defaults (TestRBACSeedMatchesDefaults).
-- Runs under the operator RLS scope (spool migrate, rdb 0014). Two nullable
-- columns and one grant row: the running image ignores all three, so this
-- file rolls before the image that reads them.

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS default_locale text NULL
        CONSTRAINT tenants_default_locale_check
        CHECK (default_locale IS NULL OR default_locale IN
            ('bg','fi','ru','en','sv','he','tr','mk','el','lt','et','lv','sr','ro','uk','sk','pl','es','nl'));

ALTER TABLE tenant_memberships
    ADD COLUMN IF NOT EXISTS disabled_at timestamptz NULL;

INSERT INTO rbac_role_permissions (role_id, permission_id)
VALUES ('biz_owner', 'members.invite')
ON CONFLICT DO NOTHING;

UPDATE rbac_roles SET description = 'the tenant owner: every permission'
 WHERE role_id = 'biz_owner';

-- 0039_rbac_customer_and_user_roles.sql — three owner decisions of
-- 2026-09-25 on the specs/025 role rows. Forward-only.
--
-- 1. A new system role biz_customer ("Biz Customer"): "figrure [sic] out a new role
--    BizCustomer ... which for now will have the same permissions as the
--    Developer role". The grant is copied from developer's rows, so it is
--    exactly developer's at apply time; later changes to either are their own
--    migration.
-- 2. A new system role regular_user ("Regular User"): "add the role for
--    regular user as sell [well], which should be the same as Developer".
--    Same copy.
-- 3. members.invite (invite AND remove members) is the admin's only: "so only
--    the admin will be able to add users to the tenant". biz_owner loses it
--    and keeps every other permission. By the no-escalation rule (025 §3.4)
--    a biz_owner can then no longer grant or manage the admin role either.
--
-- The rows MUST equal internal/rbac Defaults (TestRBACSeedMatchesDefaults).
-- Runs under the operator RLS scope (spool migrate, rdb 0014).

INSERT INTO rbac_roles (role_id, tenant_owner, description) VALUES
    ('biz_customer', false, 'a business customer: for now the developer''s grants'),
    ('regular_user', false, 'a regular user: for now the developer''s grants');

INSERT INTO rbac_role_permissions (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM (VALUES ('biz_customer'), ('regular_user')) AS r (role_id)
 CROSS JOIN rbac_role_permissions p
 WHERE p.role_id = 'developer';

DELETE FROM rbac_role_permissions
 WHERE permission_id = 'members.invite' AND role_id <> 'admin';

UPDATE rbac_roles SET description = 'the tenant owner: every permission but members.invite (admin only)'
 WHERE role_id = 'biz_owner';

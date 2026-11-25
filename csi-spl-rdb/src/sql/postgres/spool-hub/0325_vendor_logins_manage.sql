-- 0325_vendor_logins_manage.sql - who may sign a workspace's agent CLIs in
-- to their vendor subscriptions from the web UI (spec 192 section 2, build
-- row L1; SPL-6519). Forward-only, additive.
--
-- The permission vendor_logins.manage, granted to biz_owner AND admin
-- (spec 192 Q-1 A, owner HUM-10 t1 4781ca4e poll 2728652b): the two roles
-- that hold vendor_keys.manage (rdb 0232). The hub asks it on every
-- /v1/signin-relay* route, refuses it under an act-as session, and refuses
-- an operator-made manager until a confirmed manager confirms it: the same
-- two rules as vendor_keys.manage (hub/signin_relay.go). The rows MUST
-- equal internal/rbac Defaults + Permissions (store
-- TestRBACSeedMatchesDefaults).
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014). Live-data
-- safety: one catalogue row and two grants; no table rewrite. No personal
-- data, no secret. DEPLOY ORDER: wf 20 applies it before the image that
-- reads it.

SET LOCAL lock_timeout = '5s';

INSERT INTO rbac_permissions (permission_id, description) VALUES
    ('vendor_logins.manage', 'sign the workspace''s agent CLIs in and out of their vendor subscriptions');

INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES
    ('biz_owner', 'vendor_logins.manage'), ('admin', 'vendor_logins.manage');

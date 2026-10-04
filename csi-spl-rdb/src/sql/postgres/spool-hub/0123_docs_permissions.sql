-- 0123_docs_permissions.sql - docs.read and docs.write (specs/075 Phase 2,
-- T008). Forward-only, additive.
--
-- Owner, prd t1 topic 9f0d751c: "we need the functionality for all of the
-- users to be able to edit docs", "than later on use some kind of roles based
-- access to decide who gets to edit what", and (msg b60bf417) "in the
-- beginning the doc ediing should be only for people and agents , or people
-- via agents".
--
-- So both permissions go to the eight system roles BY NAME: a role added
-- later (e.g. spec 077's demo_user) holds neither until it is granted, and
-- the owner's "who edits what" is a grant change, not a code change.
--
-- The rows MUST equal internal/rbac Defaults + Permissions (store
-- TestRBACSeedMatchesDefaults). Runs under the operator RLS scope (spool
-- migrate, rdb 0014). The running image never asks for either permission, so
-- this file rolls before the image that does.

INSERT INTO rbac_permissions (permission_id, description) VALUES
    ('docs.read',  'read the workspace docs'),
    ('docs.write', 'create, edit and delete the workspace docs');

INSERT INTO rbac_role_permissions (role_id, permission_id)
SELECT r.role_id, p.permission_id
FROM (VALUES ('biz_owner'), ('product_owner'), ('admin'), ('developer'),
             ('tester'), ('pure_agent'), ('biz_customer'), ('regular_user')) AS r (role_id)
CROSS JOIN (VALUES ('docs.read'), ('docs.write')) AS p (permission_id);

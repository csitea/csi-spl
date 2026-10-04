-- 0124_demo_user_role.sql - the demo_user role and four new permissions
-- (specs/077 T002, FR-001, FR-002). Forward-only, additive.
--
-- Owner ask (HUM-10, t1 4979bb24): "a new role for users - demo users, which
-- will be able to login to the system and interact with the ai agents, but
-- have pretty restricted permissions for changes".
--
-- 1. Four new permissions close the spec's gaps on DATA, not on a role name
--    (the hub never checks a role name, 025 §3):
--      files.write   - upload and delete files, and the WUI upload token (G1)
--      topics.manage - move / merge / promote topics; create and edit issues (G3)
--      self.keys     - a human's own keys and event log writes (G2)
--      channels.edit - add or remove channel members and agents, the invite
--                      setting, archive, delete. Today a channel created by
--                      hub or wui lets ANY member add people and agents.
--    Each is granted to EVERY existing role in this file, so no real member
--    loses anything.
-- 2. The role demo_user: topics.read, notes.send, agents.command and
--    docs.read (rdb 0123 gave every role docs.read + docs.write; a visitor
--    reads the docs and writes none), nothing else. The hub grants it nothing unless SPOOL_HUB_DEMO_ENABLED is on AND
--    the tenant is the demo workspace (hub/demo.go), so this row is inert
--    while the flag is off (default, dev and prd).
--
-- The rows MUST equal internal/rbac Defaults + Permissions (store
-- TestRBACSeedMatchesDefaults). Runs under the operator RLS scope (spool
-- migrate, rdb 0014). No personal data, no secret.
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (spec 072 A45).

INSERT INTO rbac_permissions (permission_id, description) VALUES
    ('files.write',   'upload and delete files'),
    ('topics.manage', 'move, merge and promote topics; create and edit issues'),
    ('self.keys',     'add and revoke one''s own keys; write one''s own event log'),
    ('channels.edit', 'add or remove channel members and agents; archive or delete a channel');

INSERT INTO rbac_role_permissions (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM rbac_roles r
 CROSS JOIN (VALUES ('files.write'), ('topics.manage'), ('self.keys'), ('channels.edit')) AS p (permission_id);

INSERT INTO rbac_roles (role_id, tenant_owner, description) VALUES
    ('demo_user', false, 'a demo visitor from the Internet: read, post, talk to demo agents (specs/077)');

INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES
    ('demo_user', 'topics.read'),
    ('demo_user', 'notes.send'),
    ('demo_user', 'agents.command'),
    ('demo_user', 'docs.read');

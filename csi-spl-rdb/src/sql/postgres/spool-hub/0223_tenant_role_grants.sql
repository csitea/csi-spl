-- 0223_tenant_role_grants.sql - the role x action list of a workspace (spec
-- 152 v0.3 sections 3.1, 3.3 and 3.6, build row B1, SPL-3209). Forward-only,
-- additive.
--
-- 1. The 23 new action ids of spec 152 3.1, each with its system grant equal
--    to the roles that may do the action TODAY (3.6), so every workspace acts
--    exactly as before:
--      agents.dm, agents.start, agents.mention, agents.post, agents.reply
--          every role holding agents.command, demo_user included (the demo
--          is unchanged); not tester
--      issues.create, issues.edit, issues.assign, issues.prioritise,
--      issues.status
--          every role holding topics.manage (rdb 0124), so never demo_user
--          (R29: it stays refused at every issue route)
--      issues.blocker                     biz_owner (the owner flag)
--      issues.remove_others               biz_owner, admin (tenant.settings)
--      channels.ai_agents, messages.kind, topics.change_others,
--      roadmap.publish, embeds.visitors, perms.edit
--                                         biz_owner, admin (role names)
--      results.accept, ship.approve       every member role but tester
--      marketing.publish, embeds.manage   biz_owner (the owner flag)
--      reporting.sql                      admin (the role name)
--    No hub site asks them yet; the site rows (B5-B7) switch each check to
--    its id. The rows MUST equal internal/rbac Defaults + Permissions (store
--    TestRBACSeedMatchesDefaults).
--
-- 2. tenant_role_grants: one row per CHANGED cell of a workspace's list
--    (decision D1). The effective grant of a role in a tenant = the system
--    grant, minus its rows with granted = false, plus its rows with granted
--    = true (3.4). No row = today. Nothing reads or writes it yet (B3).
--    hours.rates stays pinned to time_accountant here too (rdb 0222).
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014). Live-data
-- safety: 23 catalogue rows, their grants, one new empty table; no existing
-- row changes. Runtime grants: the default privileges of
-- spool-hub-roles/runtime-grants.sql. No personal data, no secret.
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (spec 072 A45).

INSERT INTO rbac_permissions (permission_id, description) VALUES
    ('issues.create',        'file an issue'),
    ('agents.dm',            'DM an agent'),
    ('agents.start',         'open a new channel topic that addresses an agent'),
    ('agents.mention',       'address an agent in an existing topic; the mention poke'),
    ('agents.post',          'a plain channel post reaches the channel''s agents'),
    ('agents.reply',         'a reply in a channel-less topic goes on to its agent'),
    ('issues.edit',          'edit an issue, its labels and discussion links; delete or archive one''s own issue'),
    ('issues.assign',        'set an issue''s assignee'),
    ('issues.prioritise',    'set an issue''s priority or level, and a topic''s priority'),
    ('channels.ai_agents',   'switch the AI agents of a channel one did not create'),
    ('messages.kind',        'set the kind of someone else''s message'),
    ('issues.status',        'change an issue''s status: start, done, return, reopen'),
    ('issues.blocker',       'make a blocker message an issue'),
    ('topics.change_others', 'edit, delete, move, merge or promote someone else''s message or topic'),
    ('issues.remove_others', 'delete or archive someone else''s issue; restore any archived issue'),
    ('results.accept',       'accept or return an agent''s result'),
    ('ship.approve',         'give an agent the go to release or deploy'),
    ('roadmap.publish',      'make the workspace roadmap public or private; approve a roadmap goal'),
    ('marketing.publish',    'publish a marketing post'),
    ('embeds.manage',        'put a channel on a website: embeds and their keys'),
    ('perms.edit',           'edit the workspace role x action list'),
    ('reporting.sql',        'run reporting SQL'),
    ('embeds.visitors',      'see and handle website visitors: lead, block');

-- The ids that ride with an existing permission: every SYSTEM role holding it.
INSERT INTO rbac_role_permissions (role_id, permission_id)
SELECT rp.role_id, p.permission_id
  FROM rbac_role_permissions rp
  JOIN rbac_roles r ON r.role_id = rp.role_id AND r.tenant_id IS NULL
 CROSS JOIN (VALUES ('agents.dm'), ('agents.start'), ('agents.mention'), ('agents.post'), ('agents.reply'))
       AS p (permission_id)
 WHERE rp.permission_id = 'agents.command';

INSERT INTO rbac_role_permissions (role_id, permission_id)
SELECT rp.role_id, p.permission_id
  FROM rbac_role_permissions rp
  JOIN rbac_roles r ON r.role_id = rp.role_id AND r.tenant_id IS NULL
 CROSS JOIN (VALUES ('issues.create'), ('issues.edit'), ('issues.assign'), ('issues.prioritise'), ('issues.status'))
       AS p (permission_id)
 WHERE rp.permission_id = 'topics.manage';

-- The ids whose site names roles today.
INSERT INTO rbac_role_permissions (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM (VALUES ('biz_owner'), ('product_owner'), ('admin'), ('developer'), ('pure_agent'),
               ('biz_customer'), ('regular_user')) AS r (role_id)
 CROSS JOIN (VALUES ('results.accept'), ('ship.approve')) AS p (permission_id);

INSERT INTO rbac_role_permissions (role_id, permission_id)
SELECT r.role_id, p.permission_id
  FROM (VALUES ('biz_owner'), ('admin')) AS r (role_id)
 CROSS JOIN (VALUES ('channels.ai_agents'), ('messages.kind'), ('topics.change_others'), ('issues.remove_others'),
                    ('roadmap.publish'), ('perms.edit'), ('embeds.visitors')) AS p (permission_id);

INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES
    ('biz_owner', 'issues.blocker'),
    ('biz_owner', 'marketing.publish'),
    ('biz_owner', 'embeds.manage'),
    ('admin',     'reporting.sql');

CREATE TABLE tenant_role_grants (
    tenant_id     text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    role_id       text        NOT NULL REFERENCES rbac_roles (role_id) ON DELETE CASCADE,
    permission_id text        NOT NULL REFERENCES rbac_permissions (permission_id) ON DELETE CASCADE,
    granted       boolean     NOT NULL,
    set_by        text        NOT NULL CHECK (length(set_by) BETWEEN 1 AND 200),
    set_at        timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, role_id, permission_id),
    CONSTRAINT tenant_role_grants_hours_rates CHECK (permission_id <> 'hours.rates' OR role_id = 'time_accountant')
);

-- RLS in the 0021 fail-closed NULLIF shape, as topic_priorities (rdb 0214):
-- a tenant reads and writes only its own rows; the operator scope sees all.
ALTER TABLE tenant_role_grants ENABLE ROW LEVEL SECURITY;
ALTER TABLE tenant_role_grants FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON tenant_role_grants;
CREATE POLICY tenant_scope ON tenant_role_grants
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON tenant_role_grants;
CREATE POLICY operator_scope ON tenant_role_grants
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- 0021_tenant_rbac.sql — tenant roles and permissions as rows (specs/025
-- FR-001, SEC-RBAC-4). Forward-only.
--
-- The hub asks for a PERMISSION at each entry point (internal/rbac), never a
-- role name, so a changed grant is a row edit in a later file, not code.
--
-- rbac_permissions      hub-wide catalogue (no tenant column, no RLS; like humans)
-- rbac_roles            tenant_id NULL = a system role every tenant sees;
--                       a tenant id = that tenant's own role (phase 2, none yet)
-- rbac_role_permissions the grant; visible exactly when its role is
--
-- The seed below MUST equal internal/rbac Defaults + Permissions; the
-- Postgres suite asserts it (TestRBACSeedMatchesDefaults).
--
-- Owner decision 2026-09-19: "tenant owner = biz-owner" — the tenant owner is
-- the role flagged tenant_owner, not a flag on the membership. Existing rows:
-- owner -> biz_owner, member -> developer (025 OQ-8).
--
-- DEPLOY ORDER: apply this BEFORE rolling a hub that reads these tables (the
-- running image only asks "is a member"; its legacy-name writes happen only
-- on the operator path). 025 §6.

CREATE TABLE rbac_permissions (
    permission_id text PRIMARY KEY CHECK (permission_id ~ '^[a-z][a-z_]*\.[a-z][a-z_]*$'),
    description   text NOT NULL CHECK (length(description) <= 200)
);

CREATE TABLE rbac_roles (
    role_id      text        PRIMARY KEY CHECK (role_id ~ '^[a-z][a-z0-9_]{0,31}$'),
    tenant_id    text        NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    tenant_owner boolean     NOT NULL DEFAULT false,
    description  text        NOT NULL DEFAULT '' CHECK (length(description) <= 200),
    created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX rbac_roles_tenant ON rbac_roles (tenant_id) WHERE tenant_id IS NOT NULL;

CREATE TABLE rbac_role_permissions (
    role_id       text NOT NULL REFERENCES rbac_roles (role_id) ON DELETE CASCADE,
    permission_id text NOT NULL REFERENCES rbac_permissions (permission_id) ON DELETE CASCADE,
    PRIMARY KEY (role_id, permission_id)
);

INSERT INTO rbac_permissions (permission_id, description) VALUES
    ('threads.read',    'read roster, channels and threads; open the WUI socket'),
    ('notes.send',      'post a note from the WUI'),
    ('agents.command',  'command an agent through box-wui dispatch'),
    ('channels.manage', 'create channels'),
    ('members.invite',  'invite and remove members'),
    ('members.roles',   'change a member''s role'),
    ('billing.manage',  'billing, checkout and seats of the tenant'),
    ('tenant.settings', 'tenant settings'),
    ('keys.manage',     'tenant-level keys (box pins, the box-wui pin)'),
    ('audit.read',      'see the tenant audit trail');

INSERT INTO rbac_roles (role_id, tenant_owner, description) VALUES
    ('biz_owner',     true,  'the tenant owner: every permission'),
    ('product_owner', false, 'steers the work: read, write, command agents, channels, audit'),
    ('admin',         false, 'runs the tenant: members, roles, settings, keys, audit; not billing'),
    ('developer',     false, 'does the work: read, write, command agents, channels'),
    ('tester',        false, 'reads and reports: read and notes'),
    ('pure_agent',    false, 'a HUM account operated by software: read, notes, command agents');

INSERT INTO rbac_role_permissions (role_id, permission_id)
SELECT 'biz_owner', permission_id FROM rbac_permissions;

INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES
    ('product_owner', 'threads.read'), ('product_owner', 'notes.send'), ('product_owner', 'agents.command'),
    ('product_owner', 'channels.manage'), ('product_owner', 'audit.read'),
    ('admin', 'threads.read'), ('admin', 'notes.send'), ('admin', 'agents.command'),
    ('admin', 'channels.manage'), ('admin', 'members.invite'), ('admin', 'members.roles'),
    ('admin', 'tenant.settings'), ('admin', 'keys.manage'), ('admin', 'audit.read'),
    ('developer', 'threads.read'), ('developer', 'notes.send'), ('developer', 'agents.command'),
    ('developer', 'channels.manage'),
    ('tester', 'threads.read'), ('tester', 'notes.send'),
    ('pure_agent', 'threads.read'), ('pure_agent', 'notes.send'), ('pure_agent', 'agents.command');

-- Memberships and invites: the 010 CHECK becomes an FK to the role rows.
-- (spool migrate runs this file under the operator RLS scope, rdb 0014.)
ALTER TABLE tenant_memberships DROP CONSTRAINT tenant_memberships_role_check;
ALTER TABLE tenant_invites     DROP CONSTRAINT tenant_invites_role_check;
UPDATE tenant_memberships SET role = CASE role WHEN 'owner' THEN 'biz_owner' ELSE 'developer' END
 WHERE role IN ('owner', 'member');
UPDATE tenant_invites SET role = CASE role WHEN 'owner' THEN 'biz_owner' ELSE 'developer' END
 WHERE role IN ('owner', 'member');
ALTER TABLE tenant_memberships ADD CONSTRAINT tenant_memberships_role_fk
    FOREIGN KEY (role) REFERENCES rbac_roles (role_id);
ALTER TABLE tenant_invites ADD CONSTRAINT tenant_invites_role_fk
    FOREIGN KEY (role) REFERENCES rbac_roles (role_id);
CREATE INDEX tenant_memberships_role ON tenant_memberships (tenant_id, role);

-- Legacy names on WRITE: a hub image older than 025 (still running between
-- this apply and the roll) and old operator scripts write 'owner' / 'member';
-- store them as their 025 ids instead of failing the FK.
CREATE FUNCTION rbac_legacy_role() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    NEW.role := CASE NEW.role WHEN 'owner' THEN 'biz_owner' WHEN 'member' THEN 'developer' ELSE NEW.role END;
    RETURN NEW;
END
$$;
CREATE TRIGGER tenant_memberships_legacy_role BEFORE INSERT OR UPDATE OF role ON tenant_memberships
    FOR EACH ROW EXECUTE FUNCTION rbac_legacy_role();
CREATE TRIGGER tenant_invites_legacy_role BEFORE INSERT OR UPDATE OF role ON tenant_invites
    FOR EACH ROW EXECUTE FUNCTION rbac_legacy_role();

-- RLS in the 0014 shape, with the empty-setting guard (NULLIF: a pooled
-- connection reads the GUC as '' after any transaction-local set_config,
-- never NULL; CLE-3416). Reads: a tenant sees the system roles and its own;
-- writes (the FOR ALL policy): only its own rows, so a tenant can never
-- change or delete a system role. Operator scope: everything.
ALTER TABLE rbac_roles ENABLE ROW LEVEL SECURITY;
ALTER TABLE rbac_roles FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON rbac_roles FOR SELECT
    USING (tenant_id IS NULL OR tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY tenant_scope ON rbac_roles
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON rbac_roles
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE rbac_role_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE rbac_role_permissions FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_read ON rbac_role_permissions FOR SELECT
    USING (EXISTS (SELECT 1 FROM rbac_roles r WHERE r.role_id = rbac_role_permissions.role_id));
CREATE POLICY tenant_scope ON rbac_role_permissions
    USING (EXISTS (SELECT 1 FROM rbac_roles r WHERE r.role_id = rbac_role_permissions.role_id
                   AND r.tenant_id = NULLIF(current_setting('app.tenant_id', true), '')))
    WITH CHECK (EXISTS (SELECT 1 FROM rbac_roles r WHERE r.role_id = rbac_role_permissions.role_id
                        AND r.tenant_id = NULLIF(current_setting('app.tenant_id', true), '')));
CREATE POLICY operator_scope ON rbac_role_permissions
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

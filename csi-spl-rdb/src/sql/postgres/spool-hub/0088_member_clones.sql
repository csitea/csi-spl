-- 0088_member_clones.sql — admin "act as a user" via a temporary clone
-- (specs/054). Forward-only.
--
-- The owner's decision (topic 18597eaa): an admin acts as member X not by an
-- overlay on their own session but inside a NEW temporary technical human that
-- is a snapshot of X's tenant role and channel memberships. Everything the
-- clone does is the clone's; X's history is never touched. Leaving is a plain
-- sign-out. The clone expires (Sweep) and is disabled + stripped of its
-- memberships; its messages are kept, marked as test.
--
-- This file adds three things:
--   1. humans.technical  — the clone (and any future bot) is not a real seat;
--      it is filtered out of member lists, seat counts and rosters, and its
--      posts render as test. humans is hub-wide (no RLS, rdb 0006), so a plain
--      column.
--   2. members.impersonate — the permission to start an act-as, granted to
--      biz_owner and admin. The rows MUST equal internal/rbac Defaults +
--      Permissions (store TestRBACSeedMatchesDefaults). Runs under the operator
--      RLS scope (spool migrate, rdb 0014).
--   3. member_clones — one row per act-as session: who (created_by) acted as
--      whom (target_hum) in which tenant, the clone's HUM, the role snapshot,
--      when it started, when it expires, and when/why it ended. The row is the
--      durable audit trail (read via audit.read); it outlives the clone human.

ALTER TABLE humans ADD COLUMN technical boolean NOT NULL DEFAULT false;

INSERT INTO rbac_permissions (permission_id, description) VALUES
    ('members.impersonate', 'act as a member through a temporary clone');

INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES
    ('biz_owner', 'members.impersonate'),
    ('admin',     'members.impersonate');

CREATE TABLE member_clones (
    clone_hum   text        PRIMARY KEY REFERENCES humans (human_id) ON DELETE CASCADE,
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    target_hum  text        NOT NULL,   -- X, the member cloned (snapshot, no FK: rows outlive X)
    created_by  text        NOT NULL,   -- Y, the admin who started it
    role        text        NOT NULL,   -- snapshot of X's tenant role at start
    created_at  timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    ended_at    timestamptz NULL,
    end_reason  text        NULL CHECK (end_reason IN ('stop', 'expired', 'admin'))
);
CREATE INDEX member_clones_tenant  ON member_clones (tenant_id);
CREATE INDEX member_clones_live     ON member_clones (expires_at) WHERE ended_at IS NULL;

-- RLS in the 0014/0021 shape, with the empty-setting guard (NULLIF: a pooled
-- connection reads the GUC as '' after any transaction-local set_config, never
-- NULL; CLE-3416). A tenant reads and writes only its own rows; the operator
-- scope (Sweep, spool migrate) sees everything.
ALTER TABLE member_clones ENABLE ROW LEVEL SECURITY;
ALTER TABLE member_clones FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON member_clones
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON member_clones
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

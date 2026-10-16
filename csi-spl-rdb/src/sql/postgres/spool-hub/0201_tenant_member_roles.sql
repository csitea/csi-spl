-- 0201_tenant_member_roles.sql — several roles per member (specs/025 §10.2,
-- data-model §2.2-§2.3, row R1, SPL-2203). Forward-only.
--
-- Owner HUM-10 (t1 a95de1d8): one member holds several roles ("both
-- Developer, Operator, Regular User and DevOps"). A member's permissions are
-- the UNION of its set's grants.
--
-- tenant_memberships.role stays NOT NULL as the PRIMARY role: the one shown
-- first and the one every exclusive-role reader (demo_user, channel_guest,
-- 025 §10.4 list B) keeps reading unchanged. tenant_member_roles holds the
-- FULL set, the primary included. Invariant: role ∈ set, always; the
-- triggers below keep it for a raw `UPDATE tenant_memberships SET role`
-- (the operator shell actions, 074 T007) as well as for the store.
-- tenant_invite_roles is the same for an open invite (data-model §2.2).
--
-- Nobody loses a permission: the backfill writes one row per membership and
-- per invite, role_id = role, so every set is exactly today's one role.
--
-- Live-data safety: two new tables, one row per existing membership and
-- invite (a few hundred rows), triggers on two small tables. No rewrite of
-- an existing table. The hub image that reads the set ships with this file
-- (spec 072 A45: serve refuses a schema behind its image; the deploy
-- migrates before it rolls).

CREATE TABLE IF NOT EXISTS tenant_member_roles (
    tenant_id   text        NOT NULL,
    human_id    text        NOT NULL,
    role_id     text        NOT NULL REFERENCES rbac_roles (role_id),
    granted_at  timestamptz NOT NULL DEFAULT now(),
    granted_by  text        NOT NULL DEFAULT '',
    PRIMARY KEY (tenant_id, human_id, role_id),
    FOREIGN KEY (tenant_id, human_id)
        REFERENCES tenant_memberships (tenant_id, human_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS tenant_invite_roles (
    tenant_id   text NOT NULL,
    email       text NOT NULL,
    role_id     text NOT NULL REFERENCES rbac_roles (role_id),
    PRIMARY KEY (tenant_id, email, role_id),
    FOREIGN KEY (tenant_id, email)
        REFERENCES tenant_invites (tenant_id, email) ON DELETE CASCADE
);

-- The FK to rbac_roles (role_id) is checked on every rbac_roles delete.
CREATE INDEX IF NOT EXISTS tenant_member_roles_role_idx ON tenant_member_roles (role_id);
CREATE INDEX IF NOT EXISTS tenant_invite_roles_role_idx ON tenant_invite_roles (role_id);

-- RLS in the 0021 fail-closed NULLIF shape (SEC-RBAC-4).
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['tenant_member_roles', 'tenant_invite_roles'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_scope ON %I', t);
        EXECUTE format($p$CREATE POLICY tenant_scope ON %I
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))$p$, t);
        EXECUTE format('DROP POLICY IF EXISTS operator_scope ON %I', t);
        EXECUTE format($p$CREATE POLICY operator_scope ON %I
            USING (current_setting('app.rls_scope', true) = 'operator')
            WITH CHECK (current_setting('app.rls_scope', true) = 'operator')$p$, t);
    END LOOP;
END
$$;

-- Trigger 2 (data-model §2.3): demo_user and channel_guest are EXCLUSIVE, a
-- set holding one holds nothing else (spec §10.2 rule 3), so every
-- exclusive-role read stays correct on the primary alone. SQLSTATE 23514
-- with a named constraint: the store answers ErrBadRole (400 bad_role).
CREATE OR REPLACE FUNCTION tenant_member_roles_exclusive() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE
    excl text[] := ARRAY['demo_user', 'channel_guest'];
    clash boolean;
BEGIN
    IF TG_TABLE_NAME = 'tenant_member_roles' THEN
        SELECT EXISTS (SELECT 1 FROM tenant_member_roles x
            WHERE x.tenant_id = NEW.tenant_id AND x.human_id = NEW.human_id AND x.role_id <> NEW.role_id
              AND (NEW.role_id = ANY (excl) OR x.role_id = ANY (excl))) INTO clash;
    ELSE
        SELECT EXISTS (SELECT 1 FROM tenant_invite_roles x
            WHERE x.tenant_id = NEW.tenant_id AND x.email = NEW.email AND x.role_id <> NEW.role_id
              AND (NEW.role_id = ANY (excl) OR x.role_id = ANY (excl))) INTO clash;
    END IF;
    IF clash THEN
        RAISE EXCEPTION 'role % cannot share a role set with demo_user or channel_guest', NEW.role_id
            USING ERRCODE = '23514', CONSTRAINT = 'tenant_member_roles_exclusive';
    END IF;
    RETURN NEW;
END
$$;

DROP TRIGGER IF EXISTS exclusive_role ON tenant_member_roles;
CREATE TRIGGER exclusive_role BEFORE INSERT ON tenant_member_roles
    FOR EACH ROW EXECUTE FUNCTION tenant_member_roles_exclusive();
DROP TRIGGER IF EXISTS exclusive_role ON tenant_invite_roles;
CREATE TRIGGER exclusive_role BEFORE INSERT ON tenant_invite_roles
    FOR EACH ROW EXECUTE FUNCTION tenant_member_roles_exclusive();

-- Trigger 1 (data-model §2.3): the primary is kept in the set. On an insert,
-- add it; on a change from Q to R, drop Q and add R. Every other role of the
-- set stays. Q is dropped first so a move between an exclusive role and
-- another never meets trigger 2 half way.
CREATE OR REPLACE FUNCTION tenant_member_roles_primary() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    IF TG_TABLE_NAME = 'tenant_memberships' THEN
        IF TG_OP = 'UPDATE' AND OLD.role IS DISTINCT FROM NEW.role THEN
            DELETE FROM tenant_member_roles
             WHERE tenant_id = NEW.tenant_id AND human_id = NEW.human_id AND role_id = OLD.role;
        END IF;
        INSERT INTO tenant_member_roles (tenant_id, human_id, role_id, granted_by)
        VALUES (NEW.tenant_id, NEW.human_id, NEW.role, 'primary')
        ON CONFLICT DO NOTHING;
    ELSE
        IF TG_OP = 'UPDATE' AND OLD.role IS DISTINCT FROM NEW.role THEN
            DELETE FROM tenant_invite_roles
             WHERE tenant_id = NEW.tenant_id AND email = NEW.email AND role_id = OLD.role;
        END IF;
        INSERT INTO tenant_invite_roles (tenant_id, email, role_id)
        VALUES (NEW.tenant_id, NEW.email, NEW.role)
        ON CONFLICT DO NOTHING;
    END IF;
    RETURN NULL;
END
$$;

DROP TRIGGER IF EXISTS primary_role ON tenant_memberships;
CREATE TRIGGER primary_role AFTER INSERT OR UPDATE OF role ON tenant_memberships
    FOR EACH ROW EXECUTE FUNCTION tenant_member_roles_primary();
DROP TRIGGER IF EXISTS primary_role ON tenant_invites;
CREATE TRIGGER primary_role AFTER INSERT OR UPDATE OF role ON tenant_invites
    FOR EACH ROW EXECUTE FUNCTION tenant_member_roles_primary();

-- A role set change is an access change: the covered views move their stamp
-- like a tenant_memberships write (0103; store/change_stamp_test.go).
DROP TRIGGER IF EXISTS change_stamp ON tenant_member_roles;
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON tenant_member_roles
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();

-- Backfill: one row per membership and per invite, the role it holds today.
INSERT INTO tenant_member_roles (tenant_id, human_id, role_id, granted_at, granted_by)
SELECT m.tenant_id, m.human_id, m.role, m.created_at, 'migration' FROM tenant_memberships m
ON CONFLICT DO NOTHING;
INSERT INTO tenant_invite_roles (tenant_id, email, role_id)
SELECT i.tenant_id, i.email, i.role FROM tenant_invites i
ON CONFLICT DO NOTHING;

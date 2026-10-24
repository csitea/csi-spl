-- 0222_hours_v2_terminals.sql - hours tracking v2: shared terminals, member
-- PINs, the hours.rates permission and the time_accountant role (spec 107
-- v2.2, build row T065, split from T022; FR-20, FR-25, FR-37). Forward-only,
-- additive.
--
--   hours_terminals    a device an admin (tenant.settings) registered as a
--                      terminal of the workspace (FR-25): a name, the hash
--                      of the token the device holds (never the token), who
--                      registered it and when; revoked_at set = a lost
--                      terminal, refused from then on. A terminal holds no
--                      member's rights.
--   hours_member_pins  per member: the PIN hash and the optional badge hash,
--                      both keyed with the hub-held pepper (T031, never a
--                      literal), the failed-try count and locked_until (5
--                      wrong tries lock that member's PIN for 15 min). A
--                      badge identifies one member of the workspace (unique
--                      per workspace); a PIN alone identifies no one, so it
--                      is not unique.
--
-- hours.rates ("see rates and labour cost") is pinned to time_accountant
-- (FR-20): no other role holds it, the biz owner's included, and a CHECK on
-- rbac_role_permissions refuses a grant of it to any other role, a tenant's
-- own roles included (the role editor cannot add it). time_accountant holds
-- hours.read and hours.rates only: none of the four permissions every member
-- role holds (rdb 0124) and no topics.read (FR-21's external seat). Its
-- invite (access_until required) is T047's; until then no route grants it.
--
-- No money (FR-19): no rate, amount or cost column. Both tables in the 3.2
-- shape: tenant_id first (FK, ON DELETE CASCADE), ENABLE + FORCE row level
-- security, tenant_scope with the NULLIF guard, operator_scope. Runtime
-- grants: the default privileges of spool-hub-roles/runtime-grants.sql.
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014). No running
-- hub reads these tables yet (T031 does). Live-data safety: two new, empty
-- tables; three seed rows; the CHECK added to rbac_role_permissions scans
-- its few hundred rows once under an ACCESS EXCLUSIVE lock (no row holds
-- hours.rates before this file). No personal data beyond member ids, no
-- secret: only hashes.

CREATE TABLE hours_terminals (
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    terminal_id uuid        NOT NULL DEFAULT gen_random_uuid(),
    name        text        NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 100),
    token_hash  bytea       NOT NULL UNIQUE CHECK (octet_length(token_hash) BETWEEN 32 AND 64),
    created_by  text        NOT NULL CHECK (length(created_by) BETWEEN 1 AND 200),
    created_at  timestamptz NOT NULL DEFAULT now(),
    revoked_at  timestamptz NULL,
    PRIMARY KEY (tenant_id, terminal_id),
    CHECK (revoked_at IS NULL OR revoked_at >= created_at)
);

CREATE TABLE hours_member_pins (
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    member_id    text        NOT NULL CHECK (length(member_id) BETWEEN 1 AND 200),
    pin_hash     bytea       NOT NULL CHECK (octet_length(pin_hash) BETWEEN 32 AND 64),
    badge_hash   bytea       NULL CHECK (octet_length(badge_hash) BETWEEN 32 AND 64),
    failed_count integer     NOT NULL DEFAULT 0 CHECK (failed_count BETWEEN 0 AND 1000),
    locked_until timestamptz NULL,
    updated_by   text        NOT NULL CHECK (length(updated_by) BETWEEN 1 AND 200),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, member_id),
    UNIQUE (tenant_id, badge_hash)
);

-- RLS in the 0014/0021 shape, with the empty-setting guard (NULLIF, CLE-3416).
DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['hours_terminals', 'hours_member_pins'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format($p$CREATE POLICY tenant_scope ON %I
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))$p$, t);
        EXECUTE format($p$CREATE POLICY operator_scope ON %I
            USING (current_setting('app.rls_scope', true) = 'operator')
            WITH CHECK (current_setting('app.rls_scope', true) = 'operator')$p$, t);
    END LOOP;
END
$$;

INSERT INTO rbac_permissions (permission_id, description) VALUES
    ('hours.rates', 'see rates and labour cost; compute approved hours x rate');
INSERT INTO rbac_roles (role_id, tenant_owner, description) VALUES
    ('time_accountant', false, 'reads approved hours and rates; no topics, no approval (specs/107 FR-20, FR-21)');
INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES
    ('time_accountant', 'hours.read'), ('time_accountant', 'hours.rates');

ALTER TABLE rbac_role_permissions ADD CONSTRAINT hours_rates_time_accountant_only
    CHECK (permission_id <> 'hours.rates' OR role_id = 'time_accountant');

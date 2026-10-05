-- 0127_quota_counts.sql - per-human quota counters (spec 077 3.7, T013).
-- Forward-only, idempotent.
--
-- The demo caps cost by counting what a demo_user does and refusing the
-- unit past the limit BEFORE the work is built:
--
--   quota_counts  one row per (tenant, human, kind, window): n units taken.
--                 T013 counts agent turns per visit (kind agent_turn, window
--                 = the visit's tenant_memberships.created_at); T012 will
--                 count posts per minute and per day (window = the minute /
--                 the day) in the same table.
--
-- A take is one INSERT ... ON CONFLICT DO UPDATE ... WHERE n < limit: the
-- row lock orders racing takes, and a refused take writes nothing. A table,
-- not hub memory: the hub redeploys many times a day, and a counter that
-- reset on every roll would hand each visitor a fresh 20 turns. The rows go
-- with the tenant (ON DELETE CASCADE); the runtime grants come from the
-- default privileges of spool-hub-roles/runtime-grants.sql.
-- DEPLOY ORDER: before the hub that writes this table.

CREATE TABLE IF NOT EXISTS quota_counts (
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    human_id     text        NOT NULL CHECK (length(human_id) BETWEEN 1 AND 200),
    kind         text        NOT NULL CHECK (length(kind) BETWEEN 1 AND 40),
    window_start timestamptz NOT NULL,
    n            integer     NOT NULL CHECK (n >= 0),
    PRIMARY KEY (tenant_id, human_id, kind, window_start)
);

-- RLS in the 0021 fail-closed NULLIF shape: a tenant reads and writes only
-- its own rows; the operator scope (spool migrate, the sweep) sees everything.
ALTER TABLE quota_counts ENABLE ROW LEVEL SECURITY;
ALTER TABLE quota_counts FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON quota_counts;
CREATE POLICY tenant_scope ON quota_counts
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON quota_counts;
CREATE POLICY operator_scope ON quota_counts
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

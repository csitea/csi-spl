-- 0226_dm_agents.sql — the agents a person added to a direct message (spec
-- 151 section 4.1, row T001, SPL-3039; owner HUM-10, topic cf359a19, Q1 = A:
-- the agent joins the same DM). Forward-only, additive, idempotent.
--
--   dm_agents   one row per (workspace, DM, agent). A DM has no entity of its
--               own (spec 151 section 2.4): it is its two ends, stored as the
--               sorted pair a < b of id@box. origin is 'invite' while the
--               agent is in the DM and 'removed' after; the row stays, so the
--               messages the agent wrote while it was in stay readable.
--               invited_by is the HUM-* who added it, added_at the last add,
--               removed_at the last remove (NULL while 'invite').
--
-- The read door (store/view.go readableBy, store/view_postgres.go) gains one
-- case from this table: a DM message in a topic of the pair, written by an
-- agent added to it between added_at and removed_at, to one of the two ends,
-- is readable by both ends.
--
-- RLS: FORCE, the fail-closed tenant policy of 0021 (NULLIF), FOR ALL: the
-- DM agent routes (row T002) write in the workspace's own scope. The
-- operator scope is the break-glass only.
--
-- DEPLOY ORDER: wf 20 applies this file on each database before it rolls
-- the hub that bundles it; the read door reads dm_agents without a probe.
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS dm_agents (
    tenant_id   text        NOT NULL,
    a_id        text        NOT NULL,
    a_box       text        NOT NULL,
    b_id        text        NOT NULL,
    b_box       text        NOT NULL,
    agent_id    text        NOT NULL,
    agent_box   text        NOT NULL,
    origin      text        NOT NULL DEFAULT 'invite',
    invited_by  text        NOT NULL,
    added_at    timestamptz NOT NULL DEFAULT now(),
    removed_at  timestamptz NULL,
    CONSTRAINT pk_dm_agents PRIMARY KEY (tenant_id, a_id, a_box, b_id, b_box, agent_id, agent_box),
    CONSTRAINT fk_dm_agents_tenant FOREIGN KEY (tenant_id)
        REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    CONSTRAINT chk_dm_agents_origin CHECK (origin IN ('invite', 'removed')),
    CONSTRAINT chk_dm_agents_pair_sorted CHECK ((a_id || '@' || a_box) < (b_id || '@' || b_box)),
    CONSTRAINT chk_dm_agents_not_an_end CHECK (
        (agent_id, agent_box) <> (a_id, a_box) AND (agent_id, agent_box) <> (b_id, b_box)),
    CONSTRAINT chk_dm_agents_removed_at CHECK ((origin = 'removed') = (removed_at IS NOT NULL))
);
-- The read door looks a DM message's sender up as an added agent.
CREATE INDEX IF NOT EXISTS ix_dm_agents_agent
    ON dm_agents (tenant_id, agent_id, agent_box);

-- RLS, fail-closed (NULLIF): the workspace reads and writes its own rows;
-- the operator scope is the break-glass only.
ALTER TABLE dm_agents ENABLE ROW LEVEL SECURITY;
ALTER TABLE dm_agents FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON dm_agents;
CREATE POLICY tenant_scope ON dm_agents
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON dm_agents;
CREATE POLICY operator_scope ON dm_agents
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

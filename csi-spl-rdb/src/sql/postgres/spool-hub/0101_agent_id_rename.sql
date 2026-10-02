-- 0101_agent_id_rename.sql — agent ids take the new grammar c-004 next to the
-- legacy CLE-77952 (spec 061 FR-006, lane L1 T012). Forward-only.
--
-- New grammar: ^[acgq]-[0-9]{3}$, 000 never an id (spec 061 section 2). The
-- old ^[A-Z]{2,4}-[0-9]+$ stays accepted for good: it also covers HUM-, GST-
-- and every legacy id history keeps. Only the hub's write path refuses a
-- legacy agent id after 2026-10-03T20:59:59Z (agentid.LegacyUntil); the
-- stored rows stay valid.

-- 0001 / 0005: the roster (BOX- still forbidden).
ALTER TABLE roster DROP CONSTRAINT roster_agent_id_check;
ALTER TABLE roster ADD CONSTRAINT roster_agent_id_check
    CHECK (agent_id ~ '^([acgq]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]+)$' AND agent_id !~ '^BOX-');

-- 0047: an issue's assignee.
ALTER TABLE issues DROP CONSTRAINT issues_assignee_check;
ALTER TABLE issues ADD CONSTRAINT issues_assignee_check
    CHECK (assignee = '' OR assignee ~ '^([acgq]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]+)$');

-- 0096: a lane row's agent.
ALTER TABLE fleet_lanes DROP CONSTRAINT fleet_lanes_agent_id_check;
ALTER TABLE fleet_lanes ADD CONSTRAINT fleet_lanes_agent_id_check
    CHECK (agent_id ~ '^([acgq]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]{1,9})$');

-- 0097: an ask's sender, acker and closer, each <ID> or <ID>@<box>.
ALTER TABLE fleet_asks DROP CONSTRAINT fleet_asks_from_agent_check;
ALTER TABLE fleet_asks ADD CONSTRAINT fleet_asks_from_agent_check
    CHECK (from_agent ~ '^([acgq]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]{1,9})(@[a-z0-9][a-z0-9-]{0,31})?$');
ALTER TABLE fleet_asks DROP CONSTRAINT fleet_asks_acked_by_check;
ALTER TABLE fleet_asks ADD CONSTRAINT fleet_asks_acked_by_check
    CHECK (acked_by ~ '^(([acgq]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]{1,9})(@[a-z0-9][a-z0-9-]{0,31})?)?$');
ALTER TABLE fleet_asks DROP CONSTRAINT fleet_asks_closed_by_check;
ALTER TABLE fleet_asks ADD CONSTRAINT fleet_asks_closed_by_check
    CHECK (closed_by ~ '^(([acgq]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})|[A-Z]{2,4}-[0-9]{1,9})(@[a-z0-9][a-z0-9-]{0,31})?)?$');

-- The alias table (spec 061 section 5): (legacy id, box) -> new id on that
-- same box, written ONCE by do_spl_agent_id_map (lane L5) and never edited.
-- Owner 2026-10-02: no per-machine bands, every machine numbers c-004..c-999
-- on its own and the unique name is c-NNN@<box>. The hub resolves a legacy
-- id through it at the edge and serves it at GET /api/v1/agent-aliases.
CREATE TABLE agent_id_aliases (
    tenant_id text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    old_id    text        NOT NULL CHECK (old_id ~ '^(CLE|AGY|GRK|QWN)-[0-9]+$'),
    new_id    text        NOT NULL CHECK (new_id ~ '^[acgq]-(00[1-9]|0[1-9][0-9]|[1-9][0-9]{2})$'),
    kind      text        NOT NULL CHECK (kind IN ('agy', 'claude', 'grok', 'qwen')),
    box_id    text        NOT NULL CHECK (box_id ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    mapped_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, old_id, box_id)
);

-- RLS in the 0021 fail-closed NULLIF shape: a tenant reads and writes only
-- its own aliases; the operator scope (spool migrate) sees everything.
ALTER TABLE agent_id_aliases ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_id_aliases FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON agent_id_aliases
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON agent_id_aliases
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

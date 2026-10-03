-- 0107_agent_seats.sql - when an agent id was seated by its current holder
-- (spec 061 section 3.6, lane L10 T110). Forward-only.
--
-- Ids are reused (spec 061 section 3.5: 3-digit rolling ids 004-999, a 24 h
-- quarantine). History keeps the bare id, so a DM with c-004 shows the old
-- holder's messages above the new holder's. The WUI draws a divider
-- "new holder since <seated_at>" at the first message after it.
--
--   agent_seats  one row per (tenant, box, agent): seated_at is the time the
--                id ENTERED that box's roster (it was not in the box's
--                previous announcement). The retire path moves the agent's
--                spool dir away, so the box's next announcement drops the id;
--                the next holder's announcement adds it again and SetRoster
--                stamps a new seated_at. An agent that stays announced keeps
--                its row untouched. The row outlives the roster row (no FK to
--                roster: the roster is replaced on every announcement).
--
-- No backfill: an agent already in the roster when this lands was seated
-- before the hub recorded seats, and no row means "no divider".
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply BEFORE the hub that writes this table.

CREATE TABLE agent_seats (
    tenant_id text        NOT NULL,
    box_id    text        NOT NULL,
    agent_id  text        NOT NULL CHECK (length(agent_id) <= 64),
    seated_at timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, box_id, agent_id),
    FOREIGN KEY (tenant_id, box_id) REFERENCES boxes (tenant_id, box_id) ON DELETE CASCADE
);

-- RLS in the 0021 fail-closed NULLIF shape (the 0105 pair).
ALTER TABLE agent_seats ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_seats FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON agent_seats
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON agent_seats
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

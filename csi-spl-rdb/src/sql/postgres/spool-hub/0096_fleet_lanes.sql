-- 0096_fleet_lanes.sql — the fleet-wide lane map: who owns what, across
-- machines (CLE-77920, specs/058 G4 / N2). Forward-only.
--
-- Every brief tells an agent to read `git worktree list` before it takes an
-- area; that list is per machine, so a lane on the satellite was invisible to
-- a spawn on the home box and two lanes could take the same files. One row
-- per agent, addressed <ID>@<box> (the fleet naming rule, owner t1
-- 2efb3e78: box = the machine's desk box id, SPOOL_DESK_BOX): written at spawn, set to state done at exit-clean, read by
-- do_spl_lane_map on every machine.
--
-- writer_box is the box that last wrote the row, from the authenticated hello (an
-- audit column the client cannot choose). The hub prunes done rows a week
-- after their last write, so the table holds the live lanes plus a week of
-- history, not one row per agent ever spawned.
CREATE TABLE fleet_lanes (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    fleet      text        NOT NULL CHECK (fleet ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    agent_id   text        NOT NULL CHECK (agent_id ~ '^[A-Z]{2,4}-[0-9]{1,9}$'),
    agent_box  text        NOT NULL CHECK (agent_box ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    repo       text        NOT NULL DEFAULT '' CHECK (length(repo) <= 64),
    branch     text        NOT NULL DEFAULT '' CHECK (length(branch) <= 200),
    scope      text        NOT NULL DEFAULT '' CHECK (length(scope) <= 500),
    files      text[]      NOT NULL DEFAULT '{}' CHECK (cardinality(files) <= 50),
    topic      text        NOT NULL DEFAULT '' CHECK (length(topic) <= 64),
    state      text        NOT NULL CHECK (state IN ('live', 'done')),
    writer_box text        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, fleet, agent_id)
);

-- RLS in the 0021 fail-closed NULLIF shape: a tenant reads and writes only
-- its own fleet's rows; the operator scope (spool migrate) sees everything.
ALTER TABLE fleet_lanes ENABLE ROW LEVEL SECURITY;
ALTER TABLE fleet_lanes FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON fleet_lanes
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON fleet_lanes
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

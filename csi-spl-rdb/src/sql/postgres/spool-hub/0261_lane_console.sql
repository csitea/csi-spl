-- 0261_lane_console.sql - a lane's live console (spec 153 section 3.18,
-- SPL-4810; owner HUM-10, t1 27162335, msgs 038fa412, 8dd53bd9 and
-- 3b2ba6f3): an admin opens a lane from the Lanes table, clicks Console and
-- sees that lane's tmux screen, refreshed while the dialog stays open.
-- Forward-only, additive, idempotent. The next free number at build time
-- (renumbered on rebase).
--
--   lane_console  one row per (workspace, box, agent): the box's workspace,
--                 because the box writes it over its own session.
--                 demand_until is set by the hub when an allowed reader
--                 asks (POST, every 20 s while the feed shows); the box
--                 pulls the rows of its own box whose demand is still on
--                 and pushes the captured screen. The box masks it first
--                 (spool_redact plus the PEM state) and the hub stores only
--                 that: screen is the masked text, lines its line count,
--                 redactions the per-kind count removed, never what. One
--                 row is overwritten in place, never a history; a row whose
--                 demand ended an hour ago is deleted by the next demand in its workspace.
--
-- RLS: the 0242 shape, tenant_scope with NULLIF + operator_scope; a
-- statement without a tenant reads and writes no row. The runtime grants
-- come from the default privileges of spool-hub-roles/runtime-grants.sql,
-- as every table since 017. No secret by design; demanded_by is the
-- reader's human id. DEPLOY ORDER: wf 20 applies this file before it rolls
-- the hub that writes the table.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS lane_console (
    tenant_id    text        NOT NULL,
    agent_box    text        NOT NULL CHECK (length(agent_box) BETWEEN 1 AND 200),
    agent_id     text        NOT NULL CHECK (length(agent_id) BETWEEN 1 AND 64),
    demand_until timestamptz NOT NULL,
    demanded_by  text        NOT NULL DEFAULT '' CHECK (length(demanded_by) <= 200),
    screen       text        NOT NULL DEFAULT '' CHECK (octet_length(screen) <= 131072),
    lines        integer     NOT NULL DEFAULT 0 CHECK (lines >= 0),
    redactions   jsonb       NOT NULL DEFAULT '{}'::jsonb,
    captured_at  timestamptz NULL,
    CONSTRAINT pk_lane_console PRIMARY KEY (tenant_id, agent_box, agent_id)
);

ALTER TABLE lane_console ENABLE ROW LEVEL SECURITY;
ALTER TABLE lane_console FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON lane_console;
CREATE POLICY tenant_scope ON lane_console
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON lane_console;
CREATE POLICY operator_scope ON lane_console
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- 0246_channel_box_pins.sql - channel-level box pins (spec 164 v1.3
-- section 3.1, build row B1, SPL-4438; owner HUM-10, prd t1 topic 021d4921,
-- msgs f9234b11 and 6b6d092c). Forward-only, additive: one new table,
-- nothing altered. The spec names "the next free number at build time".
--
--   channel_box_pins  the boxes a channel is pinned to. No row for a channel
--                     = any pinned box of the workspace (the owner's
--                     default); one or more rows = only those boxes receive
--                     its posts, post into it as agents, or run its lanes.
--                     The FK to pins catches a box the workspace never
--                     pinned; a revoked pin keeps its row (revoked_at), so
--                     the hub's write check refuses a revoked box (spec 164
--                     4.1). A channel or pin delete takes its rows with it.
--
-- Grants: none here. runtime-grants.sql grants DML on ALL TABLES and the
-- schema owner's default privileges cover a table created later, so the
-- runtime login reads and writes this one the moment it exists.
--
-- RLS in the 0244 shape: tenant_scope with the NULLIF guard (CLE-3416) plus
-- operator_scope, ENABLE + FORCE.

CREATE TABLE IF NOT EXISTS channel_box_pins (
    tenant_id   text        NOT NULL,
    channel_id  text        NOT NULL,
    box_id      text        NOT NULL,
    pinned_at   timestamptz NOT NULL DEFAULT now(),
    pinned_by   text        NOT NULL, -- HUM-<n>, or 'operator'
    PRIMARY KEY (tenant_id, channel_id, box_id),
    FOREIGN KEY (tenant_id, channel_id) REFERENCES channels (tenant_id, channel_id) ON DELETE CASCADE,
    FOREIGN KEY (tenant_id, box_id) REFERENCES pins (tenant_id, box_id) ON DELETE CASCADE
);
-- "which channels pin this box"; the primary key serves the per-channel read.
CREATE INDEX IF NOT EXISTS channel_box_pins_box ON channel_box_pins (tenant_id, box_id);

ALTER TABLE channel_box_pins ENABLE ROW LEVEL SECURITY;
ALTER TABLE channel_box_pins FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON channel_box_pins;
CREATE POLICY tenant_scope ON channel_box_pins
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON channel_box_pins;
CREATE POLICY operator_scope ON channel_box_pins
    FOR ALL
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

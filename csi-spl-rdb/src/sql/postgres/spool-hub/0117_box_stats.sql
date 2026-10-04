-- 0117_box_stats.sql - the hardware history of the fleet's boxes: one load
-- and memory sample per box every 5 minutes. Forward-only.
--
-- Owner HUM-10, t1 8c4fcc46 ("yes"): "Add load and free memory to the status
-- row that each box already sends to the fleet. That builds a history in the
-- hub database that the web app can chart, at no cost." The lane map's
-- BOX-0@<box> row (rdb 0096) is overwritten every 300 s, so it keeps no
-- history; the same tick now also appends one row here.
--
--   box_stats   append-only. box is the machine (the lane map's agent_box,
--               the box's desk id), writer_box the box key that wrote it
--               (from the authenticated hello, never the frame), at the
--               hub's clock. The hub's retention sweep deletes rows older
--               than store.BoxStatsRetention (30 days): one row per box per
--               5 min is ~8.6k rows per box per month.
--
-- No personal data: numbers and box ids only. Each CHECK is
-- store/box_stats.go's CheckBoxStat.
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply BEFORE the hub that writes this table (wf 20 does).

CREATE TABLE box_stats (
    id           bigserial   PRIMARY KEY,
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    box          text        NOT NULL CHECK (box ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    writer_box   text        NOT NULL,
    at           timestamptz NOT NULL,
    load1        real        NOT NULL CHECK (load1 BETWEEN 0 AND 100000),
    load5        real        NOT NULL CHECK (load5 BETWEEN 0 AND 100000),
    load15       real        NOT NULL CHECK (load15 BETWEEN 0 AND 100000),
    cpus         integer     NOT NULL CHECK (cpus BETWEEN 1 AND 100000),
    mem_total_kb bigint      NOT NULL CHECK (mem_total_kb >= 0),
    mem_avail_kb bigint      NOT NULL CHECK (mem_avail_kb >= 0),
    swap_used_kb bigint      NOT NULL CHECK (swap_used_kb >= 0),
    agents_live  integer     NOT NULL CHECK (agents_live BETWEEN 0 AND 100000)
);
-- The read: one workspace's box (or every box) over a window.
CREATE INDEX box_stats_tenant_box_at ON box_stats (tenant_id, box, at);
-- The retention prune: every workspace at once.
CREATE INDEX box_stats_at ON box_stats (at);

-- RLS in the 0106 shape, with the empty-setting guard (NULLIF).
ALTER TABLE box_stats ENABLE ROW LEVEL SECURITY;
ALTER TABLE box_stats FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON box_stats
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON box_stats
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

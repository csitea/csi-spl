-- 0317_box_live_snapshot.sql - the actual box values of one snapshot (htop
-- header, df, du): seven scalar columns on box_stats, and box_snapshots, one
-- row per (workspace, box) holding the newest snapshot's detail. Forward-only.
--
-- Owner HUM-10, t1 78f0138c (msgs b27fa22f, c5acabfa, ed55626d): "I want to
-- see the ACTUAL data from the boxes", "as they would be shown from the htop
-- and du cmds", "at the moment the snaphot of their values where taken".
-- Spec 071 sections 8.4.2 and 8.6.2, build row T10 (SPL-6318).
--
--   box_stats      + cpu_pct, swap_total_kb, mem_buffers_kb, mem_cached_kb,
--                  tasks_total, tasks_running, uptime_s: small nullable
--                  scalars of the htop header. Rows written before this file
--                  and rows of older boxes read NULL. Retention (30 days) is
--                  unchanged.
--   box_snapshots  ONE row per (tenant_id, box), upserted on every tick and
--                  every refresh in the same transaction as its box_stats row
--                  (same at): per-core CPU, the user / sys / iowait split,
--                  threads and the 10 biggest directories (du). Per-sample
--                  arrays stay out of the 30-day history. at is the hub's
--                  clock; the hub's retention sweep deletes rows older than
--                  store.BoxStatsRetention (a retired box).
--
-- No personal data: numbers, box ids and directory paths whose home-directory
-- user names the box rewrote to uid-<n> before sending (spec 071 8.7.2). Each
-- CHECK is store/box_stats.go's CheckBoxStat / CheckBoxSnapshot.
--
-- ADD COLUMN without a default is catalog-only (no rewrite); each CHECK scans
-- box_stats once, which holds at most 30 days of 5-minute samples.
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply BEFORE the hub that writes these (wf 20 does).

ALTER TABLE box_stats
    ADD COLUMN cpu_pct        real    CHECK (cpu_pct BETWEEN 0 AND 100),
    ADD COLUMN swap_total_kb  bigint  CHECK (swap_total_kb >= 0),
    ADD COLUMN mem_buffers_kb bigint  CHECK (mem_buffers_kb >= 0),
    ADD COLUMN mem_cached_kb  bigint  CHECK (mem_cached_kb >= 0),
    ADD COLUMN tasks_total    integer CHECK (tasks_total BETWEEN 0 AND 4194304),
    ADD COLUMN tasks_running  integer CHECK (tasks_running BETWEEN 0 AND 4194304),
    ADD COLUMN uptime_s       bigint  CHECK (uptime_s >= 0);

CREATE TABLE box_snapshots (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    box        text        NOT NULL CHECK (box ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    writer_box text        NOT NULL,
    at         timestamptz NOT NULL,
    snapshot   jsonb       NOT NULL CHECK (jsonb_typeof(snapshot) = 'object' AND octet_length(snapshot::text) <= 16384),
    PRIMARY KEY (tenant_id, box)
);
-- The retention prune: every workspace at once.
CREATE INDEX box_snapshots_at ON box_snapshots (at);

-- RLS in the 0117 shape, with the empty-setting guard (NULLIF).
ALTER TABLE box_snapshots ENABLE ROW LEVEL SECURITY;
ALTER TABLE box_snapshots FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON box_snapshots
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON box_snapshots
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

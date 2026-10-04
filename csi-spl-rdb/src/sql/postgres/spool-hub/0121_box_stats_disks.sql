-- 0121_box_stats_disks.sql - disk total / free per mount on each box_stats
-- sample (rdb 0117). Forward-only.
--
-- Owner t1 f77c9f87 (the Boxes page wants disk too), via c-001 8c4fcc46.
--
--   box_stats.disks  a JSON array of {mount, total_kb, avail_kb}, one per
--                    real filesystem of the box (df -kP minus tmpfs,
--                    devtmpfs, overlay, squashfs), at most 16. Rows written
--                    before this file read []. Each object's shape is
--                    store/box_stats.go's CheckBoxStat; the CHECK here
--                    keeps the column an array of at most 16.
--
-- ADD COLUMN with a constant default is catalog-only (no rewrite); the CHECK
-- scans box_stats once, which holds at most 30 days of 5-minute samples.
-- DEPLOY ORDER: apply BEFORE the hub that writes the column (wf 20 does).

ALTER TABLE box_stats
    ADD COLUMN disks jsonb NOT NULL DEFAULT '[]'
    CHECK (jsonb_typeof(disks) = 'array' AND jsonb_array_length(disks) <= 16);

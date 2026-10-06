-- 0138_messages_autovacuum.sql - let autovacuum visit messages after a few
-- hundred new rows, so the visibility map keeps up with the inserts and the
-- channel counts' index-only scan stops reading the heap (api perf wave 1,
-- row ap-04, plan csi-spl-doc/doc/md/refactor-round-api-perf-plan-2026-10-06.md
-- section 0.2). Forward-only.
--
-- prd, 2026-10-06: the channel counts read Heap Fetches 3 691 of 6 917 rows
-- (EXPLAIN n=3, every run). messages is insert-heavy (n_tup_upd 2 216 of
-- n_tup_ins 22 433), and the default insert trigger is
--   autovacuum_vacuum_insert_threshold 1000
--   + autovacuum_vacuum_insert_scale_factor 0.2 x live rows
-- ~5 400 inserts at today's size: n_ins_since_vacuum stood at 4 892, the last
-- autovacuum was 2026-10-03, and only 0.62 of the pages were all-visible.
-- At 200 + 0.02 x live rows (~640 inserts today) each pass sets the new
-- pages all-visible within hours, not days. An insert-only pass is cheap: it
-- has no dead tuples to remove, mostly the map and the freeze work.
--
-- This is the one reloptions override spec 029 section 3.6 allows (owner's
-- go, HUM-10 msg 31d742b3); that paragraph's "no reloptions" stands for the
-- small HOT-updated tables.
--
-- ALTER TABLE ... SET (storage parameters) takes SHARE UPDATE EXCLUSIVE: no
-- rewrite, reads and writes continue. Re-running it sets the same values.
-- No personal data. The hub reads nothing new: no deploy order.

ALTER TABLE messages SET (
    autovacuum_vacuum_insert_scale_factor = 0.02,
    autovacuum_vacuum_insert_threshold = 200
);

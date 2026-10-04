-- 0122_dbx_index_audit.sql - the DB index audit's two changes (perf edition
-- 20261004, lane DBX; csi-spl-doc/doc/md/perf-edition-20261004-db-index-audit.md).
-- Forward-only.
--
-- 1. CREATE deliveries_sent_acked: the committed-row prune (store/retention.go
--    pruneCommitted, every hub sweep) finds its rows with
--    "state = 'sent' AND acked_at < $1". No index leads on acked_at, so each
--    run seq-scans every delivery to find what is usually nothing.
--    prd, 2026-10-04: EXPLAIN (ANALYZE, BUFFERS) of the inner select, n=3:
--    Seq Scan, 22 594 rows removed, 325 buffers, 5.6..25.2 ms, 0 rows.
--    Insights 24 h: the DELETE statement n=138, mean 74.9 ms.
--    Scratch pg 16, same shape and row count, FORCE RLS, a non-bypass role,
--    n=3: 2.7..3.9 ms (Seq Scan) -> 0.07..0.21 ms (Index Scan on this index,
--    2 buffers). Partial on state = 'sent': queued/expired rows never match.
--    Build: 28.6 ms for 22.6k rows (SHARE lock on deliveries for that time).
--
-- 2. DROP messages_search: the GIN on messages.search_tsv cannot serve the
--    hub. messages is FORCE row level security (0014), the hub login has no
--    BYPASSRLS, and tsvector @@ tsquery (ts_match_vq) is not LEAKPROOF, so
--    Postgres refuses it as an index condition under the policy (0081 dropped
--    the files GIN for the same reason). prd pg_stat_user_indexes since
--    2026-09-18: idx_scan 0, 12 MB (dev: 0, 7 MB); /v1/view/search seq-scans
--    (prd EXPLAIN n=3: Seq Scan on messages for a 0-hit term, 66..70 ms).
--    Scratch pg 16: the same query uses the GIN with RLS off and seq-scans
--    under FORCE RLS. Dropping it costs no plan, frees 12 MB of a 128 MB
--    shared_buffers, and takes the GIN off every insert and body edit
--    (scratch, 20k rows, n=3: insert 730 ms median with the GIN -> 544 ms).
--    Coupled to spec 022 section 9 (D-S1..D-S4, owner decision, open): only
--    D-S1 (a SECURITY DEFINER search function that bypasses RLS) would use
--    this GIN; it would re-create it in the same migration. 029 P7 left the
--    drop to that decision; this file asks the owner for it with the numbers.
--
-- messages_channel is NOT dropped: prd idx_scan 355 466; the channel counts'
-- per-channel newest-message probe (channels_postgres.go countsRead) uses it,
-- and messages_channel_stats cannot serve it (received_at is an INCLUDE
-- column there, not a key).
--
-- Inside the migrate transaction (no CONCURRENTLY): both tables are small.

CREATE INDEX IF NOT EXISTS deliveries_sent_acked
    ON deliveries (acked_at) WHERE state = 'sent';

DROP INDEX IF EXISTS messages_search;

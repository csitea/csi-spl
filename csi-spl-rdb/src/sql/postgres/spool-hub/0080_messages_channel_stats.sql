-- 0080_messages_channel_stats.sql — the channel list stops scanning the
-- tenant's messages heap (perf round e908f41b, lane B). Forward-only.
--
-- ViewChannels (SELECT channel, count(*), max(received_at) ... GROUP BY
-- channel) and ViewChannelStats.countsRead (the same, plus count(DISTINCT
-- from_id) posters) both read every live channel message of the tenant. Their
-- predicate is (tenant_id, channel IS NOT NULL, expires_at > now()) and they
-- need from_id and received_at. messages_channel (0002) carries
-- (tenant_id, channel, received_at) but not from_id or expires_at, so the
-- planner took a Seq Scan of the whole messages table and filtered — every
-- rendered channel sidebar read the tenant's heap.
--
-- This partial covering index answers those two aggregates from the index
-- alone (Index Only Scan): the payload columns (received_at, from_id,
-- expires_at) ride the leaf, so no heap page is touched. Measured on pg 16.14,
-- a non-superuser owner under the tenant RLS scope, t1 with 180 000 live
-- channel messages across 12 channels:
--   ViewChannels                  Seq Scan 13262+813 buffers  ->  Index Only Scan 1291 buffers
--   ViewChannelStats.countsRead   Seq Scan 14059 buffers      ->  Index Only Scan 1288 buffers
-- (~10x fewer shared buffers, so a cold cache reads a tenth of the pages).
--
-- Its key is (tenant_id, channel) only, so it does NOT overlap
-- messages_channel, whose (tenant_id, channel, received_at) key orders the
-- channel-scoped topic walk; both stay. expires_at is a payload filter, not a
-- key, so the index cannot help a range scan on it — only skip the heap.
-- No RLS clause: an index inherits the table's policies.

CREATE INDEX IF NOT EXISTS messages_channel_stats
    ON messages (tenant_id, channel) INCLUDE (received_at, from_id, expires_at)
    WHERE channel IS NOT NULL;

-- 0022_messages_thread_walk.sql — indexes for the thread list walk
-- (specs/027-spool-performance T030, CLE-3419). Forward-only; indexes only.
--
-- ViewThreads walks a tenant's messages newest first and keeps each thread's
-- latest message, so a page costs the page, not the tenant:
--   messages_received      the walk without a channel (all threads, DMs), and
--                          the (tenant_id, received_at) range the onSend
--                          rate count (CountMessagesSince) has lacked;
--   messages_dm_received   the walk over DMs only (no channel);
--   messages_task_received "is there a later message in this thread", and the
--                          per-thread aggregate in receive order.
-- A channel walk keeps using 0008's messages_channel.
--
-- Plain CREATE INDEX (migrations run in a transaction): it holds a write lock
-- on messages while it builds; retention keeps the table at 30 days.

CREATE INDEX messages_received      ON messages (tenant_id, received_at);
CREATE INDEX messages_dm_received   ON messages (tenant_id, received_at) WHERE channel IS NULL;
CREATE INDEX messages_task_received ON messages (tenant_id, task_id, received_at, msg_id);

-- 0024_retention_expiry_indexes.sql - indexes for the chunked retention sweep
-- (specs/027-spool-performance T010, CLE-3417). Forward-only; indexes only.
--
-- The sweep is global (asOperator) and now removes expired rows in bounded
-- chunks, one transaction each. 0001's messages_expires leads with tenant_id,
-- so a global "expires_at <= now LIMIT n" had no range to scan, and a walk
-- tenant by tenant cost ~3 s of round trips per idle sweep at 1,500 tenants
-- (measured, specs/027). These make each chunk, and an idle sweep, a range
-- scan whatever the tenant count:
--   messages_expires_at         DELETE FROM messages ... expires_at <= now
--   deliveries_queued_expires   UPDATE deliveries SET state = 'expired' for
--                               queued rows past their TTL (partial: only
--                               queued rows are ever swept)
--
-- DEPLOY ORDER: apply before the hub whose Sweep chunks. Either hub is correct
-- without it; the chunked one is only slow without it.
-- Plain CREATE INDEX (migrations run in a transaction): it holds a write lock
-- on the table while it builds; retention keeps the tables at 30 days.

CREATE INDEX messages_expires_at       ON messages (expires_at);
CREATE INDEX deliveries_queued_expires ON deliveries (expires_at) WHERE state = 'queued';

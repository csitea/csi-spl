-- 0257_netvisor_refresh.sql - the "Refresh now" request of the Netvisor
-- finance screen (spec 125 v0.1 section 1.3 "Refresh cadence", build row B5,
-- SPL-4732; owner HUM-10, topic fc0119cd). Forward-only, additive,
-- idempotent: a second apply changes nothing.
--
-- netvisor_settings.refresh_requested_at is when the workspace's Netvisor
-- owner last pressed "Refresh now" (POST /v1/netvisor/refresh), NULL when no
-- request is open. The main-box poller (B6) reads it through the operator
-- route GET /v1/operator/netvisor/refresh (the netvisor_ingest scope of rdb
-- 0255), and the next snapshot it files with fetched_at at or after the
-- request clears it. A column, not a table: one open request per workspace,
-- on the one row rdb 0255's owner_scope already binds (the owner sets it,
-- the ingest scope reads and clears it, nobody else reads it). It holds a
-- time, never a figure.
--
-- Live-data safety: a NULL column without a default rewrites no row; the
-- table holds at most one row per workspace. DEPLOY ORDER: wf 20 applies
-- this before the hub that reads the column rolls.

SET LOCAL lock_timeout = '5s';

ALTER TABLE netvisor_settings
    ADD COLUMN IF NOT EXISTS refresh_requested_at timestamptz NULL;

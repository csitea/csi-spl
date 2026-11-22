-- 0312_gcal_paused_at.sql - when a Google connection's sync was first paused
-- because its member left the workspace (spec 149 section 14, SPL-6272;
-- owner msg 08cec636, poll 2c0013de answer A). Forward-only, additive.
--
-- gcal_connections.paused_at: set by the sync cycle the first time it finds
-- the connection's human no longer a member (the pause of SPL-6250), kept by
-- every later hourly recheck, and cleared once the member passes the gate
-- again. A connection paused longer than cnf gcal.paused_drop_after is
-- revoked at Google and deleted by the cycle. NULL = not paused.
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014). Live-data
-- safety: one nullable column, no default (no table rewrite); the ACCESS
-- EXCLUSIVE lock is short (lock_timeout). No personal data, no secret.
-- DEPLOY ORDER: wf 20 applies it before the image that reads it.

SET LOCAL lock_timeout = '5s';

ALTER TABLE gcal_connections
    ADD COLUMN paused_at timestamptz;

-- 0233_gcal_source_sync.sql - the sync tokens of a member's existing Google
-- calendars (owner poll d93654e1 B, SPL-3852; spec 149 section 2.10).
-- Forward-only, additive.
--
-- gcal_connections.source_sync: one events.list sync token per Google
-- calendar the hub reads (read-only) into Spool besides its own "Spool Hub"
-- calendar: a JSON object, calendar id -> sync token. The hub replaces the
-- whole object at the end of each sync cycle, under the cycle's lease
-- (sync_lease_until fence, rdb 0217). '{}' = nothing read yet; a token is
-- only a Google cursor, never a credential.
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014). Live-data
-- safety: one column with a constant default (no table rewrite on
-- PostgreSQL 11+) and a CHECK that every existing row passes; the ACCESS
-- EXCLUSIVE lock is short (lock_timeout). No personal data, no secret.
-- DEPLOY ORDER: wf 20 applies it before the image that reads it.

SET LOCAL lock_timeout = '5s';

ALTER TABLE gcal_connections
    ADD COLUMN source_sync jsonb NOT NULL DEFAULT '{}'::jsonb
        CONSTRAINT gcal_connections_source_sync_check CHECK (jsonb_typeof(source_sync) = 'object');

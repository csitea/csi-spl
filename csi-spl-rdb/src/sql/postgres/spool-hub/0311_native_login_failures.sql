-- 0311_native_login_failures.sql - the per-email native sign-in lockout in
-- the database (spec 015 FR-006b, SPL-6182 defect 5). Forward-only,
-- additive, idempotent (a second apply changes nothing).
--
-- Owner HUM-10, t1 1269968d: "the limiter behaves the same across
-- instances" and "an operator can clear a user's lockout without a
-- redeploy". The per-email ceiling lived in one instance's memory, so two
-- Cloud Run instances counted apart and only a redeploy cleared it.
-- Design GO: c-001 msg af4ca2c8 (via the dispatch holder).
--
--   native_login_failures  one row per WRONG native sign-in (a right
--                          password records nothing: it never counts
--                          toward the lockout).
--     subject              the lower-cased email tried, with the same CHECK
--                          as password_credentials, and NO foreign key: an
--                          unknown address is counted exactly like a known
--                          one, so the lockout tells nobody which exist.
--     client_ip            the caller's address (edge.ClientIP). Kept on
--                          purpose: the ceiling is per (email, client IP)
--                          so a stranger's guesses from their address never
--                          lock the owner out from theirs; a tenfold
--                          ceiling over all addresses bounds a spread guess.
--                          At most 64 chars (an IPv6 literal fits).
--     failed_at            when.
-- Rows past the window are pruned by every write (auth.PgCredStore,
-- RecordLoginFailure, over the whole table: the failed_at index), so the
-- table holds at most one window of failures. An operator clears one
-- address with `spool hub-clear-lockout` (do_spl_native_lockout_clear).
-- Hub-wide like password_credentials (0009): no tenant_id, outside RLS.
--
-- Live-data safety: a new, empty table and two indexes. Runtime grants: the
-- default privileges of spool-hub-roles/runtime-grants.sql.
-- DEPLOY ORDER: wf 20 applies this file before it rolls the hub that reads it.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS native_login_failures (
    subject    text        NOT NULL CHECK (subject = lower(subject) AND length(subject) BETWEEN 3 AND 320),
    client_ip  text        NOT NULL CHECK (length(client_ip) <= 64),
    failed_at  timestamptz NOT NULL
);

CREATE INDEX IF NOT EXISTS native_login_failures_subject
    ON native_login_failures (subject, failed_at);

CREATE INDEX IF NOT EXISTS native_login_failures_failed_at
    ON native_login_failures (failed_at);

-- 0334_topic_loops_work_window.sql - a working-days + time-of-day limit on
-- a discussion loop's time triggers (spec 182 v0.12, SPL-6744; owner
-- HUM-10, t1 0cf1d4cf msg 122b69a5: "every 60 minutes, but only on working
-- days between x and y time in 24 hours format").
-- Forward-only, additive, idempotent.
--
-- topic_loops gains three columns, read in the loop's own zone (daily_tz):
--   window_from   : the window's first minute ("hh:mm"), NULL = all day;
--   window_to     : the window's last minute, inclusive; set exactly with
--                   window_from and later than it (an overnight window is
--                   refused: spec 182 v0.12);
--   workdays_only : fire only Monday to Friday (public holidays are not
--                   known).
-- Either limit is allowed only on a loop with every_hour or
-- every_n_minutes. No limit (both NULL, false) is the behaviour before
-- this file, so every stored row reads and fires as it did.
--
-- Live-data safety: ADD COLUMN with a constant default does not rewrite the
-- table; the CHECKs are added NOT VALID, so topic_loops is not scanned under
-- the ACCESS EXCLUSIVE lock (every stored row passes them anyway: the
-- columns are new), and every new or changed row is checked. lock_timeout
-- bounds the wait for that lock. No personal data, no secret.
SET LOCAL lock_timeout = '5s';

ALTER TABLE topic_loops ADD COLUMN IF NOT EXISTS window_from time;
ALTER TABLE topic_loops ADD COLUMN IF NOT EXISTS window_to time;
ALTER TABLE topic_loops ADD COLUMN IF NOT EXISTS workdays_only boolean NOT NULL DEFAULT false;

ALTER TABLE topic_loops DROP CONSTRAINT IF EXISTS topic_loops_window_check;
ALTER TABLE topic_loops ADD CONSTRAINT topic_loops_window_check
    CHECK ((window_from IS NULL) = (window_to IS NULL)
           AND (window_from IS NULL OR window_from < window_to)) NOT VALID;

ALTER TABLE topic_loops DROP CONSTRAINT IF EXISTS topic_loops_window_trigger_check;
ALTER TABLE topic_loops ADD CONSTRAINT topic_loops_window_trigger_check
    CHECK ((window_from IS NULL AND NOT workdays_only)
           OR 'every_hour' = ANY (triggers) OR 'every_n_minutes' = ANY (triggers)) NOT VALID;

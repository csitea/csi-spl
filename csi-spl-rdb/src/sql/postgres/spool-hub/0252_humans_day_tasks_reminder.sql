-- 0252_humans_day_tasks_reminder.sql - the two humans columns of the morning
-- card (spec 170 v1.5 section 11.4, build row B0, SPL-4666). Forward-only,
-- additive, idempotent. humans is hub-wide and outside row level security,
-- like the other layout choices (0070, 0120).
--
--   day_tasks_seen_on   the viewer's local date of the last time the card was
--                       shown or the To-do view's today was opened; the hub
--                       only stores the date it is handed. NULL = never seen.
--   day_tasks_reminder  the person's off switch. NULL = never picked: the
--                       default applies, the reminder on.
--                       'on'  : the card may show.
--                       'off' : the card never shows.
--
-- Catalog-only: both are nullable with no default, so Postgres adds them
-- without rewriting humans and every existing row reads NULL. The check runs
-- once over the table, under the lock this file already holds.
-- DEPLOY ORDER: no hub reads or writes them yet. They must be on dev and prd
-- BEFORE the hub of row B5: its GET /session reads every ViewPrefs column in
-- one SELECT, so a column the hub reads before it exists nulls every setting
-- (spec 170 section 11.7).

SET LOCAL lock_timeout = '5s';

ALTER TABLE humans
    ADD COLUMN IF NOT EXISTS day_tasks_seen_on date NULL,
    ADD COLUMN IF NOT EXISTS day_tasks_reminder text NULL;

ALTER TABLE humans DROP CONSTRAINT IF EXISTS humans_day_tasks_reminder_check;
ALTER TABLE humans ADD CONSTRAINT humans_day_tasks_reminder_check
    CHECK (day_tasks_reminder IS NULL OR day_tasks_reminder IN ('on','off'));

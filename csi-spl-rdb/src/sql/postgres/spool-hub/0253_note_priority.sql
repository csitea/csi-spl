-- 0253_note_priority.sql - a priority 1..5 per note, 1 the highest and 5 the
-- default, as the issues (rdb 0054, 0055) (spec 155 v1.2 section 2.9, owner
-- HUM-10, t1 2a0b4d9e msg a4c630a8, SPL-4652). Forward-only, additive,
-- idempotent: a second apply changes nothing.
--
-- A column, not a table as topic_priorities (rdb 0214). A topic's priority
-- has its own table because only the head trigger writes topic_heads. A note
-- is one row with one reader, written only by the notes store, and the list
-- reads the priority of every note it shows, so a table would add a join and
-- a second policy for nothing. The person_scope policy of rdb 0225 already
-- binds the column: a person reads and sets only their own.
--
-- NOT NULL DEFAULT 5: every existing note reads 5, and there is no "unset".
-- No index: the list reads one person's notes (at most 2 000) as before.
--
-- Live-data safety: a constant default rewrites no row; the CHECK scans a
-- small table under a short lock. DEPLOY ORDER: wf 20 applies this before the
-- hub that reads the column rolls.

ALTER TABLE personal.notes
    ADD COLUMN IF NOT EXISTS priority smallint NOT NULL DEFAULT 5
    CONSTRAINT notes_priority_range CHECK (priority BETWEEN 1 AND 5);

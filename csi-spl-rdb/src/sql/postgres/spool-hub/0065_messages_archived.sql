-- 0065_messages_archived.sql — archive a topic card (SPL-983, specs/041).
-- Forward-only.
--
-- Owner, 2026-09-26: "archive and delete a topic or msg in direct msgs (aka
-- card with is_parent=1), which if archived will add a soft delete = 1".
--
-- archived_at on the CARD row is that soft-delete flag: NULL = live, set =
-- archived (archived_by is who did it). Nothing is removed; unarchive clears
-- both. The hub stamps only a card (the first message of a non-lobby task, or
-- a level-1 lobby row), so "an archived row in task T" means "T is archived"
-- for every task except the lobby's, where it hides that row alone.
--
-- The partial index is the archived rows only: the list reads (topics,
-- search) probe it per topic, and it stays as small as the archive.

ALTER TABLE messages ADD COLUMN IF NOT EXISTS archived_at timestamptz;
ALTER TABLE messages ADD COLUMN IF NOT EXISTS archived_by text;

CREATE INDEX IF NOT EXISTS messages_archived
    ON messages (tenant_id, task_id, archived_at)
    WHERE archived_at IS NOT NULL;

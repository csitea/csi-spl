-- 0069_messages_moved.sql — move a topic to a channel, a message to a topic
-- (SPL-1024, specs/045). Forward-only.
--
-- Owner, 2026-09-27: "a starter of a topic should be able to just drag it to a
-- different channel", and "thread level msgs / cards should be draggable to a
-- different topic".
--
-- A move rewrites messages.channel (a topic) or messages.task_id /
-- parent_task_id / is_parent (a message). The signed envelope keeps where the
-- row was stored when it arrived (its HOME): a box signed it with a key the hub
-- does not hold, the 0060 constraint. So the move is HUB METADATA, like
-- kind_set_by, and these columns say where home is:
--
--   moved_at / moved_by     the latest move; NULL = the row is at home
--   moved_from_channel      its home channel (kept on a second move)
--   moved_from_task         its home task (a message move only)
--   moved_from_parent       its home parent_task_id (a message move only)
--
-- A move back home clears all five. Nothing is backfilled: every existing row
-- is at home. Five nullable columns and a partial index: the running image
-- ignores them, so this file rolls before the image that writes them.
--
-- messages_moved holds only moved rows. The send path probes it for a reply
-- that still carries a moved topic's old channel tag (spec 045 §3.7).

ALTER TABLE messages
    ADD COLUMN IF NOT EXISTS moved_at           timestamptz NULL,
    ADD COLUMN IF NOT EXISTS moved_by           text        NULL,
    ADD COLUMN IF NOT EXISTS moved_from_channel text        NULL,
    ADD COLUMN IF NOT EXISTS moved_from_task    uuid        NULL,
    ADD COLUMN IF NOT EXISTS moved_from_parent  uuid        NULL;

CREATE INDEX IF NOT EXISTS messages_moved
    ON messages (tenant_id, task_id)
    WHERE moved_at IS NOT NULL;

-- 0035_messages_is_parent_roots.sql — topic starters stay in the middle pane.
-- Forward-only.
--
-- 0034 added is_parent with default 0, so every message already stored
-- read as a reply. The middle pane hides is_parent 0. The first message
-- of each task is the card that pane shows, so those rows become 1.
-- A later message of the same task, and a row with a parent task, stays 0.
-- New rows that do not name the flag are parents too: the browser sends
-- 0 only for a reply written while the topics pane is open.

UPDATE messages AS m
SET is_parent = 1
WHERE m.is_parent = 0
  AND m.parent_task_id IS NULL
  AND NOT EXISTS (
    SELECT 1 FROM messages AS e
    WHERE e.tenant_id = m.tenant_id
      AND e.task_id = m.task_id
      AND (e.received_at, e.msg_id) < (m.received_at, m.msg_id)
  );

ALTER TABLE messages ALTER COLUMN is_parent SET DEFAULT 1;

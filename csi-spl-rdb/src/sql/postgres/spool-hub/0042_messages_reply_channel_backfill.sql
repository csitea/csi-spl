-- 0042_messages_reply_channel_backfill.sql — a thread reply carries its
-- topic's channel. Forward-only.
--
-- Until hub 0.5.4 (CLE-34977) an untagged reply under a channel topic was
-- stored with channel NULL: the WUI reply pane sends no tag and the hub only
-- mapped an untagged send to lobby on the lobby task. The per-message read
-- door (0028) then judged such a reply as a DM. The hub now inherits the
-- channel of the task's topic root (store.TopicChannel); this file gives the
-- rows stored before that the same answer. Measured 2026-09-25 17:18Z
-- (CLE-34978): dev 14 of 31 replies NULL under #lobby topics and 37 of 40
-- under #first-channel; prd 5 of 9 under #lobby.
--
-- The root is exactly what TopicChannel picks: the earliest is_parent 1 row
-- of the task. A reply whose root is a DM (channel NULL) stays NULL; a reply
-- that already names a channel is not touched. UPDATE OF channel fires no
-- 0023 period trigger.

UPDATE messages AS r
SET channel = root.channel
FROM (
    SELECT DISTINCT ON (tenant_id, task_id) tenant_id, task_id, channel
    FROM messages
    WHERE is_parent = 1
    ORDER BY tenant_id, task_id, received_at, msg_id
) AS root
WHERE r.channel IS NULL
  AND r.is_parent = 0
  AND root.tenant_id = r.tenant_id
  AND root.task_id = r.task_id
  AND root.channel IS NOT NULL;

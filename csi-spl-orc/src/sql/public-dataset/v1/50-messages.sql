-- columns: tenant_id, msg_id, task_id, parent_task_id, channel, ts, from_id, to_id, kind, body, is_parent, received_at, expires_at, msg, env, env_sig, from_box, to_box
-- Spec 091 4.1 / 4.4, allow-list v1 messages
-- (rows: exported_channel_live_unarchived_task_member_ids):
--   * its channel is an exported channel (the 40-channels.sql rule), so no
--     DM (channel NULL) and no private, deleted or archived channel;
--   * its task's first message (the card, the thread's root) is in an
--     exported channel too, and so is its parent task's card when it has one;
--   * no message of an archived task (rdb 0065: archived_at on any row of a
--     task_id means the whole task; in the lobby that drops the whole lobby
--     thread, the safe direction of spec 4.4), its parent task included;
--   * not expired.
-- The member rule (a HUM-n id that is not a member drops the message) is
-- applied by the export after the read and counted. msg, env, env_sig,
-- from_box and to_box are the 4.4 constants, emitted here, never read: msg
-- is the v:1 object rebuilt from the public columns only. archived_at is a
-- filter column (spec 5.1): named here, never emitted.
WITH exported_channels AS (
  SELECT c.channel_id
    FROM channels c
   WHERE c.tenant_id = :'ws'
     AND NOT c.is_private
     AND c.deleted_at IS NULL
     AND c.archived_at IS NULL
     AND c.channel_id <> :'topic_channel'
), archived_tasks AS (
  SELECT DISTINCT a.task_id
    FROM messages a
   WHERE a.tenant_id = :'ws' AND a.archived_at IS NOT NULL
), exported_cards AS (
  SELECT k.task_id
    FROM (SELECT DISTINCT ON (r.task_id) r.task_id, r.channel
            FROM messages r
           WHERE r.tenant_id = :'ws'
           ORDER BY r.task_id, r.ts, r.msg_id) k
   WHERE k.channel IN (SELECT channel_id FROM exported_channels)
     AND k.task_id NOT IN (SELECT task_id FROM archived_tasks)
)
SELECT m.tenant_id, m.msg_id, m.task_id, m.parent_task_id, m.channel, m.ts,
       m.from_id, m.to_id, m.kind, m.body, m.is_parent, m.received_at, m.expires_at,
       jsonb_build_object('v', 1, 'msg_id', m.msg_id, 'task_id', m.task_id, 'ts', m.ts,
                          'from', m.from_id, 'to', m.to_id, 'kind', m.kind, 'body', m.body,
                          'files', '[]'::jsonb) AS msg,
       ''::bytea AS env, '' AS env_sig, 'seed' AS from_box, 'seed' AS to_box
  FROM messages m
 WHERE m.tenant_id = :'ws'
   AND m.channel IN (SELECT channel_id FROM exported_channels)
   AND m.task_id IN (SELECT task_id FROM exported_cards)
   AND (m.parent_task_id IS NULL OR m.parent_task_id IN (SELECT task_id FROM exported_cards))
   AND m.expires_at > now()
 ORDER BY m.ts, m.msg_id

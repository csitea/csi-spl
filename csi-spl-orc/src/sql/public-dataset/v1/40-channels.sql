-- columns: tenant_id, channel_id, name, description, created_by, created_at
-- Spec 091 4.1 / 4.2 / Q9, allow-list v1 channels
-- (rows: public_not_deleted_not_archived). Public, not deleted, not archived
-- channels, never the dataset topic's channel (psql variable topic_channel,
-- cnf public_dataset.topic_channel). is_private, deleted_at and
-- archived_at are filter columns (spec 5.1): named here, never emitted.
SELECT c.tenant_id, c.channel_id, c.name, c.description, c.created_by, c.created_at
  FROM channels c
 WHERE c.tenant_id = :'ws'
   AND NOT c.is_private
   AND c.deleted_at IS NULL
   AND c.archived_at IS NULL
   AND c.channel_id <> :'topic_channel'
 ORDER BY c.channel_id

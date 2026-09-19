-- 0008_channels_threads.sql — M3 channels, threads and DMs on the wire
-- (specs/003-spool-message-bus/contracts/channels-v1.md, FR-024..FR-027).
-- Forward-only.
--
-- messages.channel / messages.parent_task_id (0001) now carry the optional
-- hub-envelope fields; channels / channel_subscriptions (0002) are written by
-- the hub from here on.

-- C3: the lobby is #lobby; stored #general rows are renamed. "general" stays
-- an accepted INPUT alias for one release (channels-v1 §1) but is never a
-- stored or creatable channel id.
UPDATE messages SET channel = 'lobby' WHERE channel = 'general';
ALTER TABLE channels ADD CONSTRAINT channels_not_general CHECK (channel_id <> 'general');

-- Every tenant has the three default channels (channels-v1 §1), existing
-- tenants now, new tenants through the trigger (whichever path creates them).
INSERT INTO channels (tenant_id, channel_id, name, created_by)
SELECT t.tenant_id, d.channel_id, d.channel_id, 'hub'
FROM tenants t CROSS JOIN (VALUES ('lobby'), ('tasks'), ('alerts')) AS d (channel_id)
ON CONFLICT (tenant_id, channel_id) DO NOTHING;

CREATE FUNCTION spool_seed_default_channels() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO channels (tenant_id, channel_id, name, created_by)
    SELECT NEW.tenant_id, d.channel_id, d.channel_id, 'hub'
    FROM (VALUES ('lobby'), ('tasks'), ('alerts')) AS d (channel_id)
    ON CONFLICT (tenant_id, channel_id) DO NOTHING;
    RETURN NEW;
END $$;

CREATE TRIGGER tenants_seed_default_channels AFTER INSERT ON tenants
    FOR EACH ROW EXECUTE FUNCTION spool_seed_default_channels();

-- Reads: channel feeds / stats and child-thread lookups (view-v1 §4.2, §4.5).
CREATE INDEX messages_channel ON messages (tenant_id, channel, received_at) WHERE channel IS NOT NULL;
CREATE INDEX messages_parent  ON messages (tenant_id, parent_task_id) WHERE parent_task_id IS NOT NULL;
CREATE INDEX channel_subscriptions_box ON channel_subscriptions (tenant_id, box_id);

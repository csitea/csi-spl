-- 0046: #feedback is the 4th default channel (channels-v1 §1; owner,
-- 2026-09-25: "add also the default feedback channel where everyone should be
-- able to tag the biz owner to provide feedback").
--
-- The Go store already lists it in store.DefaultChannels and seeds it lazily
-- (ON CONFLICT DO NOTHING). This migration keeps the database in step:
--   1. the 0008 tenant trigger seeds all FOUR defaults for a new tenant, so
--      the four share one created_at, as the three always did;
--   2. every existing tenant gets its #feedback row now, stamped with that
--      tenant's #lobby created_at so the idle defaults still tie (the channel
--      list orders idle channels by created_at, then a-z).
-- Measured before writing it: no tenant on dev or prd has a channel named
-- feedback (do_spl_db_query, 2026-09-25), so no created channel is turned
-- public by this.

CREATE OR REPLACE FUNCTION spool_seed_default_channels() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO channels (tenant_id, channel_id, name, created_by)
    SELECT NEW.tenant_id, d.channel_id, d.channel_id, 'hub'
    FROM (VALUES ('lobby'), ('tasks'), ('alerts'), ('feedback')) AS d (channel_id)
    ON CONFLICT (tenant_id, channel_id) DO NOTHING;
    RETURN NEW;
END $$;

INSERT INTO channels (tenant_id, channel_id, name, created_by, created_at)
SELECT t.tenant_id, 'feedback', 'feedback', 'hub',
       COALESCE((SELECT c.created_at FROM channels c
                 WHERE c.tenant_id = t.tenant_id AND c.channel_id = 'lobby'), now())
FROM tenants t
ON CONFLICT (tenant_id, channel_id) DO NOTHING;

-- 0173: #public is the 4th default channel. Forward-only, idempotent.
--
-- Owner, 2026-10-10 (HUM-10, msg 69e2d25f): "Create those public channels for
-- each of the workspaces which exist now. Also add that it is hard-coded ...:
-- a default public channel to all of the code which provisions a new
-- workspace, and always a new message which basically states that everything
-- here is public and visible to the whole internet." #public carries
-- announcements and releases (msg 6fb3b289); nothing leaves the hub yet.
--
-- The Go store lists it in store.DefaultChannels (ChannelPublicID) and seeds
-- it lazily (ON CONFLICT DO NOTHING), as 0046 did for #feedback:
--   1. the 0008 tenant trigger seeds all FOUR defaults for a new tenant, on
--      every path that inserts a tenants row (the hub's operator create, the
--      self-serve signup, `spool hub tenant-create`, a hand-run INSERT);
--   2. every existing tenant gets its #public row now, stamped with that
--      tenant's #lobby created_at so the idle defaults still tie.
-- The notice ("everything posted in this channel is public ...") is a SIGNED
-- message: only the hub holds the box-wui key, so the hub posts it, once per
-- tenant, under msg_id spool_public_notice_id(tenant) (hub/public_notice.go,
-- on start and every retention sweep). That fixed id is what makes it never
-- twice: messages' primary key is (tenant_id, msg_id).
-- Measured before writing it: no tenant on prd has a channel named public
-- (do_spl_db_query, 2026-10-10 17:2xZ, 14 tenants), so no created channel is
-- turned into a default by this.

CREATE OR REPLACE FUNCTION spool_seed_default_channels() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO channels (tenant_id, channel_id, name, created_by)
    SELECT NEW.tenant_id, d.channel_id, d.channel_id, 'hub'
    FROM (VALUES ('lobby'), ('alerts'), ('feedback'), ('public')) AS d (channel_id)
    ON CONFLICT (tenant_id, channel_id) DO NOTHING;
    RETURN NEW;
END $$;

-- The notice's msg_id (and task_id: it is its own topic). Go computes the
-- same value (store.PublicNoticeID); store TestDefaultChannelPublic0173 pins
-- it. The first 128 bits of a sha256, as a uuid.
CREATE OR REPLACE FUNCTION spool_public_notice_id(tenant text) RETURNS uuid
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$ SELECT substr(encode(sha256(('spool-public-notice:' || tenant)::bytea), 'hex'), 1, 32)::uuid $$;

INSERT INTO channels (tenant_id, channel_id, name, created_by, created_at)
SELECT t.tenant_id, 'public', 'public', 'hub',
       COALESCE((SELECT c.created_at FROM channels c
                 WHERE c.tenant_id = t.tenant_id AND c.channel_id = 'lobby'), now())
FROM tenants t
ON CONFLICT (tenant_id, channel_id) DO NOTHING;

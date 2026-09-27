-- 0067_tenant_fallback_responders.sql — no human post goes unheard while an
-- agent is online (SPL-997, specs/038 FR-030..FR-038). Forward-only.
--
-- Owner, 2026-09-27 (prd t1 #spool-hub-devel, topic 1451c158): "as long as
-- there is even 1 agent online ... it should get informed and react". A
-- human post in a channel (or a DM) whose member agents are all offline
-- reached nobody; now the hub also hands it to ONE fallback agent.
--
-- tenants.responders: the tenant's designated responder list, an ordered
-- list of agent ids. The first one online takes the post; with none online
-- (or an empty list) the hub picks the longest-online agent of the tenant.
-- Set with the csi-spl-orc action do_spl_tenant_responders. Empty = unset.
--
-- fallback_deliveries: one row per fallback delivery - which post, in which
-- channel ('' = a DM), went to which agent on which box, when. The channel
-- Properties dialog reads it ("fallback responder" line) and the SPL-997
-- measurement counts it. The post itself is in messages/deliveries as ever;
-- this row dies with the message (ON DELETE CASCADE).
--
-- RLS: the 0021 fail-closed form, matching messages. A nullable-free column
-- with a default and a new table: the running image ignores both, so this
-- file rolls before the image that reads them.

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS responders text[] NOT NULL DEFAULT '{}'
    CONSTRAINT tenants_responders_check CHECK (cardinality(responders) <= 20);

CREATE TABLE IF NOT EXISTS fallback_deliveries (
    tenant_id    text        NOT NULL,
    msg_id       uuid        NOT NULL,
    channel_id   text        NOT NULL DEFAULT '',
    box_id       text        NOT NULL,
    agent_id     text        NOT NULL,
    delivered_at timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, msg_id),
    FOREIGN KEY (tenant_id, msg_id) REFERENCES messages (tenant_id, msg_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS fallback_deliveries_channel
    ON fallback_deliveries (tenant_id, channel_id, delivered_at DESC);

ALTER TABLE fallback_deliveries ENABLE ROW LEVEL SECURITY;
ALTER TABLE fallback_deliveries FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON fallback_deliveries
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON fallback_deliveries
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

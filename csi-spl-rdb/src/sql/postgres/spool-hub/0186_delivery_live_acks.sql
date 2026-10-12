-- 0186_delivery_live_acks.sql - the box's live ack per (message, agent)
-- (spec 053 §4.2 S1, SPL-1239; read by the S3 nack escalation, SPL-1241).
-- Forward-only.
--
-- deliveries.state = 'sent' says the hub wrote the frame to a box, and
-- acked_at (rdb 0100) that the box wrote the inbox copy. Neither says a LIVE
-- agent was told: a channel post fanned to the shared desk box reads sent and
-- acked while every agent there is long gone (spec 053 §3). A box whose hello
-- carries the live_ack feature now reports, per agent a recv frame addressed,
-- what its poke did: 'shown' in a live pane (the ack), or 'no_window',
-- 'refused', 'exited' (a nack; spool-notify.sh exit 5, 6, 7). The latest poke
-- of a (message, agent) replaces the earlier one.
--
-- The hub writes a row only when it sent the message to that box, so the
-- table holds one row per delivered (message, agent) of upgraded boxes; a box
-- without the feature writes none.

CREATE TABLE delivery_live_acks (
    tenant_id text        NOT NULL,
    msg_id    uuid        NOT NULL,
    agent_id  text        NOT NULL CHECK (length(agent_id) BETWEEN 1 AND 64),
    box_id    text        NOT NULL CHECK (box_id ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    outcome   text        NOT NULL CHECK (outcome IN ('shown', 'no_window', 'refused', 'exited')),
    acked_at  timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, msg_id, agent_id),
    FOREIGN KEY (tenant_id, msg_id) REFERENCES messages (tenant_id, msg_id) ON DELETE CASCADE
);

-- The S3 sweep reads the recent nacks of a tenant every relay tick: empty
-- while every poke lands.
CREATE INDEX delivery_live_acks_nacks ON delivery_live_acks (tenant_id, acked_at)
    WHERE outcome <> 'shown';

ALTER TABLE delivery_live_acks ENABLE ROW LEVEL SECURITY;
ALTER TABLE delivery_live_acks FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON delivery_live_acks
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON delivery_live_acks
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

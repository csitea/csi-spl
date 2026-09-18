-- 0002_channels.sql — M3 channel tables (specs/003-spool-message-bus/data-model.md).
-- Forward-only. Materialised now so the schema reads as one piece; the M1 hub
-- does not read or write them (messages.channel stays NULL in M1).

CREATE TABLE channels (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    channel_id text        NOT NULL CHECK (channel_id ~ '^[a-z0-9][a-z0-9-]{0,63}$'),
    name       text        NOT NULL,
    created_by text        NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    is_private boolean     NOT NULL DEFAULT false,
    PRIMARY KEY (tenant_id, channel_id)
);

CREATE TABLE channel_subscriptions (
    tenant_id     text        NOT NULL,
    channel_id    text        NOT NULL,
    agent_id      text        NOT NULL,
    box_id        text        NOT NULL,
    subscribed_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, channel_id, agent_id, box_id),
    FOREIGN KEY (tenant_id, channel_id) REFERENCES channels (tenant_id, channel_id) ON DELETE CASCADE
);

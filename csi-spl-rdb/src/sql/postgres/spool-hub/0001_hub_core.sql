-- 0001_hub_core.sql — spool hub core schema (specs/003-spool-message-bus/data-model.md §2).
-- Forward-only. Applied by `spool migrate` in filename order, one transaction
-- per file, tracked in spool_schema_migrations. Every row carries tenant_id
-- (FR-015). No private key, token or signed URL is ever stored here (FR-014).

-- tenants (owned by 006) -----------------------------------------------------
CREATE TABLE tenants (
    tenant_id      text        PRIMARY KEY
                               CHECK (tenant_id ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    root_pubkey    bytea       NOT NULL CHECK (octet_length(root_pubkey) = 32),
    billing_status text        NOT NULL DEFAULT 'internal'
                               CHECK (billing_status IN ('active', 'grace', 'unpaid', 'internal')),
    plan_id        text        NOT NULL DEFAULT 'default',
    created_at     timestamptz NOT NULL DEFAULT now()
);

-- boxes (owned by 004) -------------------------------------------------------
CREATE TABLE boxes (
    tenant_id     text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    box_id        text        NOT NULL CHECK (box_id ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    last_hello_at timestamptz NULL,
    -- Reserved, unused in M1 (OQ-06): always NULL, nothing reads or writes it.
    iam_principal text        NULL,
    PRIMARY KEY (tenant_id, box_id)
);

-- pins: BOX pubkeys, tenant-root signed (004 / 006) --------------------------
CREATE TABLE pins (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    box_id     text        NOT NULL CHECK (box_id ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    pubkey     bytea       NOT NULL CHECK (octet_length(pubkey) = 32),
    updated_at timestamptz NOT NULL DEFAULT now(),
    revoked_at timestamptz NULL,
    PRIMARY KEY (tenant_id, box_id)
);

CREATE TABLE pins_history (
    tenant_id text        NOT NULL,
    box_id    text        NOT NULL,
    pubkey    bytea       NOT NULL,
    at        timestamptz NOT NULL DEFAULT now(),
    reason    text        NOT NULL CHECK (reason IN ('pin', 'force', 'revoke'))
);
CREATE INDEX pins_history_tenant_box ON pins_history (tenant_id, box_id, at);

-- roster: agent ids a box announced (persisted, OQ-05) -----------------------
CREATE TABLE roster (
    tenant_id    text        NOT NULL,
    box_id       text        NOT NULL,
    agent_id     text        NOT NULL CHECK (agent_id ~ '^[A-Z]{2,4}-[0-9]+$'),
    announced_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, box_id, agent_id),
    FOREIGN KEY (tenant_id, box_id) REFERENCES boxes (tenant_id, box_id) ON DELETE CASCADE
);

-- messages: one row per box-signed envelope ----------------------------------
CREATE TABLE messages (
    tenant_id      text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    msg_id         uuid        NOT NULL,
    task_id        uuid        NOT NULL,
    parent_task_id uuid        NULL,
    channel        text        NULL,
    ts             timestamptz NOT NULL,
    from_box       text        NOT NULL,
    from_id        text        NOT NULL,
    to_box         text        NOT NULL,
    to_id          text        NOT NULL,
    kind           text        NOT NULL CHECK (kind IN ('task', 'result', 'note', 'reject')),
    body           text        NOT NULL,
    files          jsonb       NOT NULL DEFAULT '[]'::jsonb,
    msg            jsonb       NOT NULL,
    env_sig        text        NOT NULL,
    -- The canonical envelope bytes the hub verified; forwarded unchanged.
    env            bytea       NOT NULL,
    received_at    timestamptz NOT NULL DEFAULT now(),
    -- Retention (limits.md): received_at + 7 d for channel 'alerts', else + 30 d.
    expires_at     timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, msg_id)
);
CREATE INDEX messages_to      ON messages (tenant_id, to_box, to_id, ts);
CREATE INDEX messages_task    ON messages (tenant_id, task_id, ts);
CREATE INDEX messages_from    ON messages (tenant_id, from_box, from_id, ts);
CREATE INDEX messages_expires ON messages (tenant_id, expires_at);

-- deliveries: the hub queue, one row per message per recipient box -----------
-- state is what the HUB knows: queued | sent | expired. The send-result values
-- 'local' and 'pending' never reach the hub (data-model.md §2a). No 'acked':
-- the hub's responsibility ends at frame delivery (OQ-08).
CREATE TABLE deliveries (
    tenant_id   text        NOT NULL,
    msg_id      uuid        NOT NULL,
    to_box      text        NOT NULL,
    state       text        NOT NULL DEFAULT 'queued'
                            CHECK (state IN ('queued', 'sent', 'expired')),
    received_at timestamptz NOT NULL DEFAULT now(),
    expires_at  timestamptz NOT NULL,
    sent_at     timestamptz NULL,
    PRIMARY KEY (tenant_id, msg_id, to_box),
    FOREIGN KEY (tenant_id, msg_id) REFERENCES messages (tenant_id, msg_id) ON DELETE CASCADE
);
CREATE INDEX deliveries_queue ON deliveries (tenant_id, to_box, state, expires_at);

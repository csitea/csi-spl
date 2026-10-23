-- 0217_google_calendar.sql - per-member Google Calendar connect (spec 149
-- v1.0 section 3, build row B1, SPL-3123). Forward-only, additive.
--
--   gcal_connections   one row per member per workspace: the Google account,
--                      the target calendar, the sealed tokens (090 sealer,
--                      never plain), the sync cursors, the sync lease and
--                      the push channel (watch_*)
--   gcal_event_map     one row per synced event: the Spool event, its Google
--                      id, etag and sync_hash (spec 149 section 2.5)
--
-- RLS in the 0187 shape (tenant_scope + operator_scope, empty-setting guard).
-- The push channel's columns are watch_*, never channel_id: these tables hold
-- no Spool channel (store/channel_scope_rls_test.go lists every table with a
-- channel column that lacks a channel_scope policy).
-- Member isolation inside a workspace is the store's (spec 149 C3).

CREATE TABLE gcal_connections (
    connection_id   uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    human_id        text        NOT NULL REFERENCES humans (human_id) ON DELETE CASCADE,
    google_email    text        NOT NULL CHECK (length(google_email) BETWEEN 3 AND 320),
    calendar_id     text        NOT NULL DEFAULT '' CHECK (length(calendar_id) <= 255),
    status          text        NOT NULL DEFAULT 'connected'
        CHECK (status IN ('connected', 'error', 'revoked')),
    status_detail   text        NOT NULL DEFAULT '' CHECK (length(status_detail) <= 500),
    access_sealed   text        NOT NULL,
    refresh_sealed  text        NOT NULL,
    kms_key_id      text        NOT NULL,
    access_expiry   timestamptz NOT NULL,
    sync_token      text        NULL,
    out_cursor      timestamptz NULL,
    due_at          timestamptz NOT NULL DEFAULT now(),
    sync_lease_until timestamptz NULL,
    watch_channel_id  uuid      NULL,
    watch_resource_id text      NULL,
    watch_expiry      timestamptz NULL,
    last_synced_at  timestamptz NULL,
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, human_id)
);
CREATE INDEX gcal_connections_due ON gcal_connections (due_at) WHERE status = 'connected';
CREATE UNIQUE INDEX gcal_connections_watch ON gcal_connections (watch_channel_id) WHERE watch_channel_id IS NOT NULL;

CREATE TABLE gcal_event_map (
    connection_id   uuid        NOT NULL REFERENCES gcal_connections (connection_id) ON DELETE CASCADE,
    tenant_id       text        NOT NULL,
    event_id        uuid        NOT NULL,
    google_id       text        NOT NULL CHECK (length(google_id) BETWEEN 1 AND 1024),
    etag            text        NOT NULL DEFAULT '',
    sync_hash       text        NOT NULL CHECK (length(sync_hash) = 64),
    synced_at       timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (connection_id, event_id),
    UNIQUE (connection_id, google_id),
    FOREIGN KEY (tenant_id, event_id) REFERENCES calendar_events (tenant_id, event_id) ON DELETE CASCADE
);

ALTER TABLE gcal_connections ENABLE ROW LEVEL SECURITY;
ALTER TABLE gcal_connections FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON gcal_connections
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON gcal_connections
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE gcal_event_map ENABLE ROW LEVEL SECURITY;
ALTER TABLE gcal_event_map FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON gcal_event_map
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON gcal_event_map
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

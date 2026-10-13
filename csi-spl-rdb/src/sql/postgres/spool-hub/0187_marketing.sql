-- 0187_marketing.sql - spec 090 phase 1 tables: a connected LinkedIn account,
-- its sealed token, the shares made with it and their audit trail (SPL-1634;
-- owner HUM-10, topic add4fbf4 msgs 06f5fd99, 489d18e6: every new spool-hub
-- blog post is shared on the owner's LinkedIn profile, with no approval
-- step). Forward-only, additive: four new tables, nothing altered.
--
--   marketing_channels        one connected account per (workspace, platform,
--                             platform member id). delegated_by is the member
--                             who connected it. auto_publish: share every new
--                             blog post without a review (the owner's word).
--                             baseline_at: when the share sweep recorded the
--                             posts already live, so connecting never
--                             re-shares the back catalogue. reminded_at: the
--                             re-connect reminder for this expires_at is sent.
--   marketing_channel_tokens  the OAuth access token, ONLY as the KMS envelope
--                             ciphertext of internal/marketing/seal.go (spec
--                             090 FR-002). No plaintext column exists.
--   marketing_posts           one row per (channel, source): the UNIQUE key is
--                             what makes a share happen at most once, across
--                             every hub instance. status: skipped (the
--                             baseline), scheduled, dispatching (claimed, the
--                             LinkedIn call in flight), published, failed.
--   marketing_post_events     the append-only audit trail of every step.
--
-- The tenant column is tenant_id (spec 090 section 12 says workspace_id in
-- prose). RLS in the 0091 shape. The events table refuses UPDATE and DELETE
-- except a tenant delete's cascade (the 0171 usage_events trigger shape) and
-- has no FK to posts or channels, so no channel delete reaches the trail.
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (spec 072 A45;
-- wf 20 migrates before it rolls).

CREATE TABLE marketing_channels (
    channel_id    uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id     text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    platform      text        NOT NULL CHECK (platform IN ('linkedin')),
    account_type  text        NOT NULL DEFAULT 'personal' CHECK (account_type IN ('personal')),
    account_ref   text        NOT NULL,              -- the platform member id (LinkedIn userinfo sub)
    account_name  text        NOT NULL DEFAULT '',
    delegated_by  text        NOT NULL,              -- the member (HUM id) who connected it
    auto_publish  boolean     NOT NULL DEFAULT false,
    status        text        NOT NULL CHECK (status IN ('active', 'revoked', 'expired')),
    expires_at    timestamptz NULL,
    reminded_at   timestamptz NULL,
    baseline_at   timestamptz NULL,
    created_at    timestamptz NOT NULL DEFAULT now(),
    updated_at    timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, platform, account_ref)
);

CREATE TABLE marketing_channel_tokens (
    channel_id  uuid        PRIMARY KEY REFERENCES marketing_channels (channel_id) ON DELETE CASCADE,
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    ciphertext  text        NOT NULL,
    kms_key_id  text        NOT NULL,
    updated_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE marketing_posts (
    post_id          uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id        text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    channel_id       uuid        NOT NULL REFERENCES marketing_channels (channel_id) ON DELETE CASCADE,
    source_type      text        NOT NULL CHECK (source_type IN ('blog')),
    source_ref       text        NOT NULL,           -- the blog post id (its slug)
    content_text     text        NOT NULL DEFAULT '',
    status           text        NOT NULL CHECK (status IN ('skipped', 'scheduled', 'dispatching', 'published', 'failed')),
    attempts         integer     NOT NULL DEFAULT 0,
    next_attempt_at  timestamptz NULL,
    claimed_at       timestamptz NULL,
    published_at     timestamptz NULL,
    platform_post_id text        NULL,
    last_error       text        NULL,               -- never a token: an HTTP status and LinkedIn's message
    created_at       timestamptz NOT NULL DEFAULT now(),
    updated_at       timestamptz NOT NULL DEFAULT now(),
    UNIQUE (channel_id, source_type, source_ref)
);
-- the share sweep reads a channel's due rows
CREATE INDEX marketing_posts_due ON marketing_posts (channel_id, status, next_attempt_at);

CREATE TABLE marketing_post_events (
    event_id    bigint      GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    channel_id  uuid        NOT NULL,
    post_id     uuid        NULL,
    event_type  text        NOT NULL CHECK (event_type IN (
                    'channel_connect', 'channel_expired', 'channel_reminder',
                    'post_baseline', 'post_scheduled', 'post_dispatched', 'post_published', 'post_failed')),
    actor_type  text        NOT NULL CHECK (actor_type IN ('human', 'system')),
    actor_id    text        NOT NULL DEFAULT '',
    details     jsonb       NOT NULL DEFAULT '{}'::jsonb,
    created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX marketing_post_events_channel ON marketing_post_events (tenant_id, channel_id, event_id DESC);

-- Append-only: no UPDATE ever; a DELETE only as a tenant delete's cascade.
CREATE FUNCTION marketing_post_events_append_only() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    IF TG_OP = 'DELETE' AND pg_trigger_depth() > 1 THEN
        RETURN OLD;
    END IF;
    RAISE EXCEPTION 'marketing_post_events is append-only: % refused (only a tenant delete removes rows)', TG_OP;
END $$;
CREATE TRIGGER append_only BEFORE UPDATE OR DELETE ON marketing_post_events
    FOR EACH ROW EXECUTE FUNCTION marketing_post_events_append_only();

-- RLS in the 0091 shape, with the empty-setting guard (NULLIF; CLE-3416).
ALTER TABLE marketing_channels ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing_channels FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON marketing_channels
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON marketing_channels
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE marketing_channel_tokens ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing_channel_tokens FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON marketing_channel_tokens
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON marketing_channel_tokens
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE marketing_posts ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing_posts FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON marketing_posts
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON marketing_posts
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE marketing_post_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing_post_events FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON marketing_post_events
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON marketing_post_events
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- 0125_calendar.sql - the calendar section (specs/089, T002). Forward-only,
-- additive.
--
--   calendar_events   one workspace's events. audience is public by default
--                     (owner decision D2); private is owner-only and filtered
--                     in the store (T003): RLS holds the workspace only, as
--                     the hub sets no per-viewer setting. mentions holds the
--                     human UUIDs and agent ids named with @. remind_at is
--                     the pop-up time (D4); no delivery state is stored.
--   official_days     shared reference (no tenant_id): a region's public
--                     holidays. No rows yet.
--   tenants.calendar_region  the workspace's region for official_days,
--                     empty by default.
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply BEFORE the hub that reads these tables (T003/T004).

CREATE TABLE calendar_events (
    event_id        uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id       text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    title           text        NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    description     text        NOT NULL DEFAULT '' CHECK (length(description) <= 4000),
    kind            text        NOT NULL CHECK (kind IN ('release', 'deploy', 'maintenance', 'freeze', 'agent_task', 'reminder', 'other')),
    starts_at       timestamptz NOT NULL,
    ends_at         timestamptz NOT NULL,
    all_day         boolean     NOT NULL DEFAULT false,
    audience        text        NOT NULL DEFAULT 'public' CHECK (audience IN ('public', 'internal', 'private')),
    mentions        text[]      NOT NULL DEFAULT '{}',
    creator_type    text        NOT NULL CHECK (creator_type IN ('human', 'agent', 'system')),
    creator_id      text        NOT NULL CHECK (length(creator_id) BETWEEN 1 AND 64),
    remind_at       timestamptz NULL,
    topic_id        text        NULL,
    release_version text        NULL CHECK (release_version IS NULL OR release_version ~ '^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c[0-9]+)?$'),
    created_at      timestamptz NOT NULL DEFAULT now(),
    updated_at      timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT calendar_events_valid_range CHECK (ends_at >= starts_at)
);
-- The range read and the year marks.
CREATE INDEX calendar_events_tenant_range ON calendar_events (tenant_id, starts_at, ends_at);
-- The private filter's viewer = ANY (mentions).
CREATE INDEX calendar_events_mentions ON calendar_events USING gin (mentions);
-- The viewer's reminders in a window.
CREATE INDEX calendar_events_remind ON calendar_events (tenant_id, remind_at) WHERE remind_at IS NOT NULL;

-- RLS in the 0106 shape, with the empty-setting guard (NULLIF).
ALTER TABLE calendar_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE calendar_events FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON calendar_events
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON calendar_events
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

CREATE TABLE official_days (
    region text NOT NULL CHECK (length(region) BETWEEN 2 AND 16),
    day    date NOT NULL,
    title  text NOT NULL CHECK (length(title) BETWEEN 1 AND 200),
    PRIMARY KEY (region, day)
);

ALTER TABLE tenants ADD COLUMN calendar_region text NOT NULL DEFAULT '';

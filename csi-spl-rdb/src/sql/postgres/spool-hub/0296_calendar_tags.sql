-- 0296_calendar_tags.sql - event tags with colours, per workspace (SPL-5883,
-- spec 097 section 11.3, build row T1). Forward-only, additive and
-- idempotent (IF NOT EXISTS, DROP POLICY IF EXISTS): a re-run is a no-op.
--
--   calendar_tags            the workspace's tag catalogue. tag_id is 8 hex
--                            chars minted by the hub; name is unique per
--                            workspace ignoring case; color is one of the 11
--                            calendar palette names (the theme variables), so
--                            a tag reads in both themes. position orders the
--                            catalogue.
--   calendar_events.tag_ids  the event's tags IN ORDER: tag_ids[1] is the
--                            first tag, the one the stripe shows. At most 10.
--                            An array has no foreign key: the hub checks every
--                            id against the workspace's catalogue on write,
--                            and a tag delete strips it from every event.
--
-- RLS: tenant_scope and operator_scope, the pattern of every tenant table.
-- The 0125 policies on calendar_events cover the new column.
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply BEFORE the hub that reads it (wf 20 does). The column
-- has a constant default, so the add is catalogue-only.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS calendar_tags (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    tag_id     text        NOT NULL CHECK (tag_id ~ '^[0-9a-f]{8}$'),
    name       text        NOT NULL CHECK (length(name) BETWEEN 1 AND 40),
    color      text        NOT NULL CHECK (color IN ('tomato', 'flamingo', 'tangerine', 'banana', 'sage',
                               'basil', 'peacock', 'blueberry', 'lavender', 'grape', 'graphite')),
    position   integer     NOT NULL DEFAULT 0 CHECK (position >= 0),
    created_by text        NOT NULL CHECK (length(created_by) BETWEEN 1 AND 64),
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, tag_id)
);
CREATE UNIQUE INDEX IF NOT EXISTS calendar_tags_name ON calendar_tags (tenant_id, lower(name));

ALTER TABLE calendar_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE calendar_tags FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON calendar_tags;
CREATE POLICY tenant_scope ON calendar_tags
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON calendar_tags;
CREATE POLICY operator_scope ON calendar_tags
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE calendar_events ADD COLUMN IF NOT EXISTS tag_ids text[] NOT NULL DEFAULT '{}'
    CHECK (cardinality(tag_ids) <= 10);
CREATE INDEX IF NOT EXISTS calendar_events_tags ON calendar_events USING gin (tag_ids)
    WHERE cardinality(tag_ids) > 0;

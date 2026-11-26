-- 0328_topic_tags.sql - tags on channel topics (spec 196 v0.3 section 2.1,
-- build row T1, SPL-6562). Forward-only, idempotent (a second apply changes
-- nothing).
--
-- Owner HUM-10 (t1 ec5e6237): "a user should be able to set tags on the
-- topics level"; one tag list per workspace (form dece6b4a #2A), always
-- lower case (form 115fd5b2 #2A), typed freely on a topic (dece6b4a #3A).
--
--   topic_tags        the workspace's tag list: one canonical NFC lower-case
--                     slug per tag (no display name, #2A). A tag no topic
--                     uses any more is pruned by the store (spec 196 2.2).
--   topic_tag_links   one row per (topic, tag), at most 10 per topic (the
--                     store's cap, spec 196 2.3).
--   topic_tag_stamps  one row per topic whose tags ever changed: the
--                     newest add or remove, for the reconnect delta (a
--                     removed link leaves no row), and the per-topic lock
--                     row of a tag write (spec 196 2.3).
--
-- Side tables keyed by (tenant_id, task_id), as topic_priorities (rdb 0214)
-- and topic_pauses (rdb 0297): topic_heads is a trigger projection of
-- messages (rdb 0144). B-tree join indexes, not a text[] GIN, which FORCE
-- RLS cannot serve (rdb 0296).
--
-- The change_stamp trigger (rdb 0103) on topic_tags and topic_tag_links: a
-- tag write moves the tenant's stamp, so a stamped repeat read
-- (hub/view_stamp.go) never answers 304 with the old tags
-- (store/change_stamp_test.go). topic_tag_stamps is written in the same
-- transaction as a link, so it needs none.
--
-- Live-data safety: three new, empty tables; no existing table is touched.
-- Runtime grants: the default privileges of spool-hub-roles/runtime-grants.sql.
-- DEPLOY ORDER: any time before the hub that reads it (spec 196 row T2).

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS topic_tags (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    tag_id     uuid        NOT NULL,
    slug       text        NOT NULL CHECK (char_length(slug) BETWEEN 1 AND 40 AND octet_length(slug) <= 128),
    created_by text        NOT NULL CHECK (char_length(created_by) BETWEEN 1 AND 64),
    created_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, tag_id),
    UNIQUE (tenant_id, slug)
);

CREATE TABLE IF NOT EXISTS topic_tag_links (
    tenant_id text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    task_id   uuid        NOT NULL,
    tag_id    uuid        NOT NULL,
    added_by  text        NOT NULL CHECK (char_length(added_by) BETWEEN 1 AND 64),
    added_at  timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, task_id, tag_id),
    FOREIGN KEY (tenant_id, tag_id) REFERENCES topic_tags (tenant_id, tag_id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS topic_tag_links_by_tag
    ON topic_tag_links (tenant_id, tag_id, task_id);

CREATE TABLE IF NOT EXISTS topic_tag_stamps (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    task_id    uuid        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, task_id)
);

-- RLS in the 0021 fail-closed NULLIF shape, as topic_priorities (rdb 0214):
-- a tenant reads and writes only its own rows; the operator scope sees
-- everything.
ALTER TABLE topic_tags ENABLE ROW LEVEL SECURITY;
ALTER TABLE topic_tags FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON topic_tags;
CREATE POLICY tenant_scope ON topic_tags
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON topic_tags;
CREATE POLICY operator_scope ON topic_tags
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE topic_tag_links ENABLE ROW LEVEL SECURITY;
ALTER TABLE topic_tag_links FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON topic_tag_links;
CREATE POLICY tenant_scope ON topic_tag_links
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON topic_tag_links;
CREATE POLICY operator_scope ON topic_tag_links
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE topic_tag_stamps ENABLE ROW LEVEL SECURITY;
ALTER TABLE topic_tag_stamps FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON topic_tag_stamps;
CREATE POLICY tenant_scope ON topic_tag_stamps
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON topic_tag_stamps;
CREATE POLICY operator_scope ON topic_tag_stamps
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

DROP TRIGGER IF EXISTS change_stamp ON topic_tags;
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON topic_tags
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();

DROP TRIGGER IF EXISTS change_stamp ON topic_tag_links;
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON topic_tag_links
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();

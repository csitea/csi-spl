-- 0274_marketing_drafts.sql - spec 090 section 22 (SPL-5240, epic SPL-2376):
-- a workspace writes its own marketing posts. Owner HUM-10, t1 19ef7d51
-- (2026-11-09): "any person with either a business owner or admin role in a
-- workspace to create content in that workspace and to post that content";
-- poll c1d8be01 Q2 A: the author publishes it, no approval step.
-- Forward-only: one new table and one CHECK swap to a wider list, so every
-- existing row still passes.
--
--   marketing_drafts              one post a member of the workspace wrote:
--                                 its text and an optional picture (a public
--                                 https URL Meta fetches; Instagram needs
--                                 it). author_id is the member (HUM id) who
--                                 wrote it, the only one who edits,
--                                 deletes or publishes it. published_at is
--                                 the first publish: from then on the text
--                                 is what went out, so it is never edited
--                                 or deleted.
--   marketing_posts.source_type   + draft: a publish of a marketing_drafts
--                                 row on one channel; source_ref is its
--                                 draft_id. The (channel, source) UNIQUE key
--                                 keeps it to once per channel, like a blog
--                                 post.
--
-- RLS in the 0187 shape (tenant_scope + operator_scope, FORCE): a workspace
-- reads and writes only its own drafts.
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (wf 20 migrates
-- before it rolls): the hub reads the new table and writes source 'draft'.

SET LOCAL lock_timeout = '5s';

CREATE TABLE marketing_drafts (
    draft_id     uuid        PRIMARY KEY DEFAULT gen_random_uuid(),
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    author_id    text        NOT NULL,
    body         text        NOT NULL CHECK (char_length(body) BETWEEN 1 AND 3000),
    image_url    text        NOT NULL DEFAULT '' CHECK (image_url = '' OR image_url LIKE 'https://%'),
    published_at timestamptz NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now()
);
-- the editor lists a workspace's drafts, last changed first
CREATE INDEX marketing_drafts_tenant ON marketing_drafts (tenant_id, updated_at DESC);

ALTER TABLE marketing_posts DROP CONSTRAINT marketing_posts_source_type_check;
ALTER TABLE marketing_posts ADD CONSTRAINT marketing_posts_source_type_check
    CHECK (source_type IN ('blog', 'draft'));

ALTER TABLE marketing_drafts ENABLE ROW LEVEL SECURITY;
ALTER TABLE marketing_drafts FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON marketing_drafts
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON marketing_drafts
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

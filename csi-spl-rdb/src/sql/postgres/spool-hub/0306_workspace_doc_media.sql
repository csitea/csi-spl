-- 0306_workspace_doc_media.sql - the media index of the Qto docs: which
-- picture, video, audio or other file each document holds in its
-- workspace's own docs bucket (spec 190 v1.0 section 5, row D1, gap G3;
-- owner HUM-10, t1 bc3df46d, msgs b04212f4 and 653f9c91: Q1 A, Q4 B, Q6 A;
-- SPL-6152). Forward-only, additive, idempotent: a second apply changes
-- nothing.
--
--   workspace_doc_media  one row per (document, sha256): the upload route
--                        (hub wsdoc_media_av.go) writes it with ON CONFLICT
--                        DO NOTHING before it promotes the bytes to
--                        qto-media/<doc>/<sha256>.<ext>. The doc's text stays
--                        the truth of what is shown; the row is what the
--                        issue door (C1), the sweep (C7) and the quota read.
--     ext                the stored extension: the media type's (C3), or a
--                        kind 'file' name's, 'bin' when it has none.
--     kind               image | video | audio | file (Q4 B).
--     name               the file name the uploader sent ('' = none), for
--                        the download card and its attachment name.
--     unnamed_since      NULL while a section body of the doc carries the
--                        token /media/<sha256>.<ext>; else when the sweep
--                        first saw it carry none. The sweep drops the row,
--                        then the object, 7 days later (Q6 A).
--                        The FK cascades: a deleted document's rows go with
--                        it, and workspace_doc_gone below holds the time.
--   human_lock           RESTRICTIVE, as 0256's on workspace_doc_item: a row
--                        passes only when its document is visible to the
--                        same statement, so a document locked to one human
--                        hides its media rows from every other reader, the
--                        sweep included (which then keeps them).
--   workspace_doc_gone   one row per deleted document: when it went. Written
--                        by the BEFORE DELETE trigger below, under the
--                        deleter's own scope (the document is visible to
--                        whoever deletes it). It tells the sweep "deleted"
--                        apart from "locked to someone else": both read as
--                        no visible document, and only the first may lose
--                        its files. The sweep deletes the document's
--                        qto-media/<doc>/ and .doctree/<doc>/ objects 7 days
--                        after gone_at, then the row. No FK: the row must
--                        outlive its document, and a workspace delete
--                        cascades through this trigger too (the sweep walks
--                        live workspaces only). It holds ids and a time,
--                        no title and no text.
--
-- RLS in the 0021 fail-closed NULLIF shape (0157's pair) on both tables.
-- Live-data safety: two new empty tables; CREATE TRIGGER on workspace_doc
-- takes a SHARE ROW EXCLUSIVE lock for a catalog change only, hence
-- lock_timeout. No row changes. Runtime grants: the default privileges of
-- spool-hub-roles/runtime-grants.sql. DEPLOY ORDER: wf 20 applies this
-- before it rolls the hub that writes the tables. Runs under the operator
-- RLS scope (spool migrate, rdb 0014). No personal data, no secret.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS workspace_doc_media (
    tenant_id     text        NOT NULL,
    doc_id        uuid        NOT NULL,
    sha256        text        NOT NULL CHECK (sha256 ~ '^[0-9a-f]{64}$'),
    ext           text        NOT NULL CHECK (ext ~ '^[a-z0-9]{1,16}$'),
    kind          text        NOT NULL CHECK (kind IN ('image', 'video', 'audio', 'file')),
    bytes         bigint      NOT NULL CHECK (bytes >= 0),
    name          text        NOT NULL DEFAULT '' CHECK (length(name) <= 255),
    created_by    text        NOT NULL DEFAULT '' CHECK (length(created_by) <= 200),
    created_at    timestamptz NOT NULL DEFAULT now(),
    unnamed_since timestamptz NULL,
    CONSTRAINT workspace_doc_media_pk PRIMARY KEY (tenant_id, doc_id, sha256),
    CONSTRAINT workspace_doc_media_doc_fk FOREIGN KEY (tenant_id, doc_id)
        REFERENCES workspace_doc (tenant_id, id) ON DELETE CASCADE
);
CREATE INDEX IF NOT EXISTS workspace_doc_media_unnamed
    ON workspace_doc_media (tenant_id, unnamed_since) WHERE unnamed_since IS NOT NULL;

CREATE TABLE IF NOT EXISTS workspace_doc_gone (
    tenant_id text        NOT NULL,
    doc_id    uuid        NOT NULL,
    gone_at   timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT workspace_doc_gone_pk PRIMARY KEY (tenant_id, doc_id)
);

ALTER TABLE workspace_doc_media ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_doc_media FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON workspace_doc_media;
CREATE POLICY tenant_scope ON workspace_doc_media
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON workspace_doc_media;
CREATE POLICY operator_scope ON workspace_doc_media
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
DROP POLICY IF EXISTS human_lock ON workspace_doc_media;
CREATE POLICY human_lock ON workspace_doc_media AS RESTRICTIVE
    USING (doc_id IN (SELECT d.id FROM workspace_doc d))
    WITH CHECK (doc_id IN (SELECT d.id FROM workspace_doc d));

ALTER TABLE workspace_doc_gone ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_doc_gone FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON workspace_doc_gone;
CREATE POLICY tenant_scope ON workspace_doc_gone
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON workspace_doc_gone;
CREATE POLICY operator_scope ON workspace_doc_gone
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- The deleter's scope writes the row: a document is deleted only by a
-- statement that can see it, so the tenant matches and the policy passes.
CREATE OR REPLACE FUNCTION workspace_doc_gone_mark() RETURNS trigger
    LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO workspace_doc_gone (tenant_id, doc_id) VALUES (OLD.tenant_id, OLD.id)
        ON CONFLICT (tenant_id, doc_id) DO NOTHING;
    RETURN OLD;
END
$$;

DROP TRIGGER IF EXISTS workspace_doc_gone_mark ON workspace_doc;
CREATE TRIGGER workspace_doc_gone_mark BEFORE DELETE ON workspace_doc
    FOR EACH ROW EXECUTE FUNCTION workspace_doc_gone_mark();

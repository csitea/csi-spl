-- 0307_workspace_doc_asset_held.sql - one lock-blind boolean for the orphan
-- sweep: does some document of the session's tenant name a picture sha256 in
-- its root item's attrs.assets (bug round 34 row 01, SPL-6180; spec 125 B8;
-- spec 137 unified-fs.md section 7). Forward-only, additive, idempotent: the
-- whole file can run a second time and changes nothing.
--
-- The defect: store.DocAssetHeld read workspace_doc_item in the tenant scope,
-- and rdb 0256's human_lock hides every item of a document locked to a human
-- unless app.doc_human_id is that human. The orphan sweep carries no human,
-- so a locked document's pictures read as unnamed and were deleted once
-- older than the 24 h grace. The sweep needs one boolean, so it gets one
-- door that answers only that, on rdb 0143's pattern:
--
-- 1. spool_doc_asset_reader, NOLOGIN NOBYPASSRLS. Nothing logs in as it. The
--    migrator becomes a member WITH INHERIT FALSE, SET TRUE (Cloud SQL needs
--    SET ROLE before a function can be handed to it), never by inheritance.
--    The runtime login is never a member.
-- 2. Column SELECT on workspace_doc_item (tenant_id, doc_id, parent_id,
--    attrs) and on workspace_doc (id): the columns the function and 0256's
--    item policy read. No write grant and no new permissive policy: the
--    function still reads only the rows tenant_scope (0157) lets through,
--    the session tenant's.
-- 3. human_lock on workspace_doc_item (0256) gains one term: a row passes
--    also when current_user is spool_doc_asset_reader, which it is only
--    inside the function below (SECURITY DEFINER runs as its owner). 0256's
--    lock is AS RESTRICTIVE with no TO clause, so it binds a NOBYPASSRLS
--    owner too; without the term the door would be as blind as before. The
--    lock on workspace_doc and workspace_doc_rev_log is unchanged: the
--    reader still sees no title and no revision of a locked document.
-- 4. spool_doc_asset_held(sha text) RETURNS boolean: LANGUAGE sql STABLE
--    SECURITY DEFINER, created AS spool_doc_asset_reader so that role owns
--    it, search_path ending in pg_temp and the body naming
--    public.workspace_doc_item. No tenant parameter: it pins the session's
--    app.tenant_id, so a caller cannot probe another tenant. It returns
--    EXISTS only: no title, item, attrs or doc id of a locked document leaves
--    it (spec 125 B8, constraints C7-C9). EXECUTE is revoked from PUBLIC;
--    the schema owner holds it WITH GRANT OPTION, so
--    roles/runtime-grants.sql grants it to the runtime login.
--
-- Live-data safety: no row is written. ALTER POLICY holds ACCESS EXCLUSIVE
-- on workspace_doc_item until COMMIT, hence lock_timeout. DEPLOY ORDER: wf 20
-- applies this before the hub that calls the function rolls. Runs under the
-- operator RLS scope (spool migrate, rdb 0014). No personal data, no secret.

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spool_doc_asset_reader') THEN
        BEGIN
            CREATE ROLE spool_doc_asset_reader NOLOGIN NOBYPASSRLS;
        EXCEPTION WHEN duplicate_object OR unique_violation THEN
            NULL; -- created by a concurrent migrator of another database
        END;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_auth_members
                   WHERE roleid = 'spool_doc_asset_reader'::regrole
                     AND member = current_user::regrole
                     AND set_option AND NOT inherit_option) THEN
        BEGIN
            GRANT spool_doc_asset_reader TO CURRENT_USER WITH INHERIT FALSE, SET TRUE;
        EXCEPTION WHEN unique_violation THEN
            NULL; -- granted by a concurrent migrator of another database
        END;
    END IF;
END
$$;

GRANT USAGE, CREATE ON SCHEMA public TO spool_doc_asset_reader;
GRANT SELECT (tenant_id, doc_id, parent_id, attrs) ON workspace_doc_item TO spool_doc_asset_reader;
GRANT SELECT (id) ON workspace_doc TO spool_doc_asset_reader;

ALTER POLICY human_lock ON workspace_doc_item
    USING (current_user = 'spool_doc_asset_reader' OR doc_id IN (SELECT d.id FROM workspace_doc d));

-- As spool_doc_asset_reader, then back to the migrator's own role: CREATE OR
-- REPLACE on the second run is the owner's own replace, never an OWNER TO.
DO $$
DECLARE
    me    text := current_user;
    owner text := (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.workspace_doc_item'::regclass);
BEGIN
    SET LOCAL ROLE spool_doc_asset_reader;
    CREATE OR REPLACE FUNCTION public.spool_doc_asset_held(sha text)
        RETURNS boolean
        LANGUAGE sql STABLE SECURITY DEFINER
        SET search_path = pg_catalog, public, pg_temp
    AS $fn$
        SELECT EXISTS (
            SELECT 1 FROM public.workspace_doc_item i,
                jsonb_each_text(CASE WHEN jsonb_typeof(i.attrs->'assets') = 'object'
                                     THEN i.attrs->'assets' ELSE '{}'::jsonb END) a
            WHERE i.tenant_id = NULLIF(current_setting('app.tenant_id', true), '')
              AND i.parent_id IS NULL
              AND a.value = sha)
    $fn$;
    REVOKE ALL ON FUNCTION public.spool_doc_asset_held(text) FROM PUBLIC;
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.spool_doc_asset_held(text) TO %I WITH GRANT OPTION', owner);
    EXECUTE format('SET LOCAL ROLE %I', me);
END
$$;

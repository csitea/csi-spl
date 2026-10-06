-- 0141_messages_search_index.sql - S1r, the message search index
-- (specs/100 T002, spec sections 5.1 and 9 P1). Forward-only, additive,
-- idempotent: the whole file can run a second time and changes nothing.
--
-- rdb 0122 dropped the old GIN on messages.search_tsv: messages is FORCE RLS
-- (rdb 0014) and ts_match_vq is not LEAKPROOF, so the planner never used it
-- under the tenant policy. S1r reads a new index through ONE door instead:
--
-- 1. spool_search_reader, NOLOGIN NOBYPASSRLS (precedent rdb 0126), so a
--    policy can name it. Nothing logs in as it. The migrator (the schema
--    owner) becomes a member WITH INHERIT FALSE, SET TRUE: it can SET ROLE to
--    it, which Cloud SQL requires before a function can be handed to it (P0
--    G7), but never holds its privileges by inheritance. The runtime login is
--    never a member (spec section 6, T4).
-- 2. btree_gin, and messages_search USING gin (tenant_id, search_tsv): the
--    tenant column leads, so one tenant never pays for another's matches.
--    Plain CREATE INDEX: a SHARE lock on messages (writes wait, reads go on)
--    for the build, 2 732 ms for 13 057 rows on Cloud SQL dev (P0 G2, n=1),
--    about 4.7 s scaled to prd's 22 369 rows. Under the spec's few-second
--    line, so no CONCURRENTLY task (T003).
-- 3. spool_search_candidates(q, cap): LANGUAGE sql STABLE SECURITY DEFINER
--    ROWS 200 (spec 5.1), created AS spool_search_reader so that role owns
--    it (it needs CREATE on schema public for that, P0 G7), search_path
--    ending in pg_temp and the body naming public.messages, so a temp table
--    called messages cannot shadow it. It pins the session tenant and returns
--    at most cap + 1 candidate ids; the hub's own statement refilters them
--    under FORCE RLS. EXECUTE is revoked from PUBLIC; the schema owner holds
--    it WITH GRANT OPTION, so roles/runtime-grants.sql (run as the owner)
--    grants it to the runtime login.
-- 4. Column SELECT on messages (the four columns the function reads, no body)
--    and the policy search_reader_all FOR SELECT TO spool_search_reader USING
--    (true). No write grant, no write policy. Last, because CREATE POLICY
--    holds an ACCESS EXCLUSIVE lock on messages until COMMIT.
--
-- lock_timeout 5s: on a busy messages table the file fails fast instead of
-- queueing every write behind its lock wait. Runs under the operator RLS
-- scope (spool migrate, rdb 0014). No personal data, no secret.

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spool_search_reader') THEN
        BEGIN
            CREATE ROLE spool_search_reader NOLOGIN NOBYPASSRLS;
        EXCEPTION WHEN duplicate_object OR unique_violation THEN
            NULL; -- created by a concurrent migrator of another database
        END;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_auth_members
                   WHERE roleid = 'spool_search_reader'::regrole
                     AND member = current_user::regrole
                     AND set_option AND NOT inherit_option) THEN
        BEGIN
            GRANT spool_search_reader TO CURRENT_USER WITH INHERIT FALSE, SET TRUE;
        EXCEPTION WHEN unique_violation THEN
            NULL; -- granted by a concurrent migrator of another database
        END;
    END IF;
END
$$;

CREATE EXTENSION IF NOT EXISTS btree_gin;

CREATE INDEX IF NOT EXISTS messages_search ON messages USING gin (tenant_id, search_tsv);

GRANT USAGE, CREATE ON SCHEMA public TO spool_search_reader;

-- As spool_search_reader, then back to the migrator's own role: CREATE OR
-- REPLACE on the second run is the owner's own replace, never an OWNER TO.
DO $$
DECLARE
    me    text := current_user;
    owner text := (SELECT pg_get_userbyid(relowner) FROM pg_class WHERE oid = 'public.messages'::regclass);
BEGIN
    SET LOCAL ROLE spool_search_reader;
    CREATE OR REPLACE FUNCTION public.spool_search_candidates(q tsquery, cap int)
        RETURNS TABLE (msg_id uuid, received_at timestamptz)
        LANGUAGE sql STABLE SECURITY DEFINER ROWS 200
        SET search_path = pg_catalog, public, pg_temp
    AS $fn$
        SELECT m.msg_id, m.received_at FROM public.messages m
        WHERE m.tenant_id = NULLIF(current_setting('app.tenant_id', true), '')
          AND m.search_tsv @@ q
        LIMIT cap + 1
    $fn$;
    REVOKE ALL ON FUNCTION public.spool_search_candidates(tsquery, int) FROM PUBLIC;
    EXECUTE format('GRANT EXECUTE ON FUNCTION public.spool_search_candidates(tsquery, int) TO %I WITH GRANT OPTION', owner);
    EXECUTE format('SET LOCAL ROLE %I', me);
END
$$;

GRANT SELECT (tenant_id, msg_id, received_at, search_tsv) ON messages TO spool_search_reader;

DROP POLICY IF EXISTS search_reader_all ON messages;
CREATE POLICY search_reader_all ON messages FOR SELECT TO spool_search_reader USING (true);

-- 0197_channel_scope_hub_logins.sql - the channel rule on messages binds the
-- hub's logins, not the search-index reader (SPL-1832; owner HUM-10, t1
-- 659e3927, poll 49b211d7, answer A). Forward-only, idempotent.
--
-- rdb 0169 made channel_scope on messages RESTRICTIVE TO public, so it also
-- bound spool_search_reader (rdb 0143), the role spool_search_candidates
-- runs as. Under a restrictive policy Postgres only takes a LEAKPROOF qual
-- into an index, and `@@` (ts_match_vq) is not: the GIN messages_search
-- (tenant_id, search_tsv) was read by tenant only and the word checked on
-- every row of the tenant. prd t1, 2026-10-14, n=1 per word: 73 539
-- buffers for a rare word (3.3 s cold), 24 024 for "archive".
--
-- 1. spool_channel_scoped, NOLOGIN NOBYPASSRLS: the logins the channel rule
--    binds. A policy TO a role binds every role that inherits it.
-- 2. Members WITH INHERIT TRUE: the migrator (this login) and every other
--    login that can read a column of messages today (the hub's runtime
--    login, the public export login), never spool_search_reader nor a
--    predefined pg_* role. The runtime login is added again by
--    spool-hub-roles/runtime-grants.sql after every migrate (a fresh
--    database migrates before that login exists). A login that never sets
--    app.channel_scope (the export login) reads the same with or without.
-- 3. ALTER POLICY channel_scope ON messages TO spool_channel_scoped: USING
--    and WITH CHECK are unchanged. The ten other channel_scope tables keep
--    TO public: the reader reads messages only.
--
-- Why it is safe: spool_search_candidates returns candidate ids only; the
-- hub's own statement re-reads every row as the runtime login under every
-- policy, channel_scope included, so a visitor still reads its one channel
-- (spec 121). Only a session that sets app.channel_scope (the hub's visitor
-- path, the runtime login) is affected by the policy at all.
-- Tests: store TestRLSChannelScopeHubNotReader (the members, the plan of
-- the reader's word match, and its control on the 0169 shape).
--
-- lock_timeout 5s: ALTER POLICY holds ACCESS EXCLUSIVE on messages until
-- COMMIT, so on a busy table the file fails fast instead of queueing every
-- write. Runs under the operator RLS scope (spool migrate, rdb 0014). No
-- personal data, no secret.

SET LOCAL lock_timeout = '5s';

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spool_channel_scoped') THEN
        BEGIN
            CREATE ROLE spool_channel_scoped NOLOGIN NOBYPASSRLS;
        EXCEPTION WHEN duplicate_object OR unique_violation THEN
            NULL; -- created by a concurrent migrator of another database
        END;
    END IF;
END
$$;

DO $$
DECLARE
    r name;
BEGIN
    FOR r IN SELECT rolname FROM pg_roles
             WHERE rolname NOT IN ('spool_search_reader', 'spool_channel_scoped') AND NOT rolsuper
               AND rolname NOT LIKE 'pg\_%'
               AND (rolname = current_user
                    OR (rolcanlogin AND has_any_column_privilege(oid, 'public.messages', 'SELECT')))
             ORDER BY rolname
    LOOP
        IF NOT EXISTS (SELECT 1 FROM pg_auth_members
                       WHERE roleid = 'spool_channel_scoped'::regrole AND member = r::regrole AND inherit_option) THEN
            BEGIN
                EXECUTE format('GRANT spool_channel_scoped TO %I WITH INHERIT TRUE', r);
            EXCEPTION WHEN unique_violation THEN
                NULL; -- granted by a concurrent migrator of another database
            END;
        END IF;
    END LOOP;
END
$$;

ALTER POLICY channel_scope ON messages TO spool_channel_scoped;

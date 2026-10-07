-- runtime-grants.sql - DML-only privileges for the hub's RUNTIME login
-- (017 T029 / FR-SEC-014). NOT a migration (outside spool-hub/). psql runs it
-- AS THE SCHEMA OWNER after every `spool migrate`, with
--   :runtime_role  the runtime login (cnf hub.db_user)
-- Idempotent: re-running changes nothing.
--
-- The runtime login owns nothing, so it cannot ALTER TABLE ... NO FORCE ROW
-- LEVEL SECURITY, DROP POLICY or DROP a table. It reads and writes rows,
-- still bound by the tenant policies. No TRUNCATE, REFERENCES or TRIGGER.
-- The default privileges cover tables, sequences and functions the owner
-- creates in later migrations, so a new table works for the hub the moment
-- it exists.

GRANT USAGE ON SCHEMA public TO :"runtime_role";

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO :"runtime_role";
-- humans_seq (nextval) and the identity column of human_keys
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO :"runtime_role";
-- the trigger functions and message_period() (PUBLIC has EXECUTE by default;
-- explicit, so a later REVOKE FROM PUBLIC cannot break the hub)
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA public TO :"runtime_role";
-- spec 100 S1r (rdb 0143): the one door to the search index. Its owner is
-- spool_search_reader and PUBLIC has no EXECUTE, so it is named here; the
-- schema owner holds EXECUTE on it WITH GRANT OPTION (rdb 0143). The runtime
-- login is never a member of spool_search_reader.
GRANT EXECUTE ON FUNCTION public.spool_search_candidates(tsquery, int) TO :"runtime_role";

-- The migrator's ledger is read (do_spl_db_rls_check), never written, by the hub.
REVOKE INSERT, UPDATE, DELETE ON spool_schema_migrations FROM :"runtime_role";

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"runtime_role";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO :"runtime_role";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO :"runtime_role";

-- SPL-984 (spec 029 D3): ceilings for the runtime login, so one stuck
-- statement or an abandoned transaction cannot hold a connection, a lock or
-- the vacuum horizon forever (both were 0 = unlimited). Measured 2026-09-26
-- (Query Insights, 7 d, prd): the hub's longest statement took 2.6 s. A
-- session that needs longer sets its own (the search seed and purge already
-- SET statement_timeout = 0). Applies to NEW sessions: the hub pool picks it
-- up as connections recycle. Undo: ALTER ROLE ... RESET <setting>.
ALTER ROLE :"runtime_role" SET statement_timeout = '30s';
ALTER ROLE :"runtime_role" SET idle_in_transaction_session_timeout = '60s';

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

-- The migrator's ledger is read (do_spl_db_rls_check), never written, by the hub.
REVOKE INSERT, UPDATE, DELETE ON spool_schema_migrations FROM :"runtime_role";

ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO :"runtime_role";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO :"runtime_role";
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT EXECUTE ON FUNCTIONS TO :"runtime_role";

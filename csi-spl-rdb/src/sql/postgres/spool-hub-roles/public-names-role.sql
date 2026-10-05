-- public-names-role.sql - the names step's LOGIN (spec 091 T004; spec 5.5
-- item 3). NOT a migration (outside spool-hub/). psql runs it AS THE SCHEMA
-- OWNER from csi-spl-orc do_spl_public_export_role, with
--   :names_verifier  the password as a SCRAM-SHA-256 verifier, computed client
--                    side from the Secret Manager slot (cnf
--                    public_dataset.names_password_secret)
--
-- Its one purpose: the gate's content scan must find every OTHER workspace's
-- id and display name, which the export login cannot read by design (fence
-- 2). So this login holds SELECT (tenant_id, display_name) ON tenants and
-- nothing else, and reads it under the operator scope (rdb 0014). It writes
-- the list to private staging only (T005). LOGIN, NOINHERIT, no CREATEDB /
-- CREATEROLE, no memberships, owns nothing; the flags it may not name keep
-- their default (off), and the caller reads every one back. Idempotent.

SELECT 'CREATE ROLE spool_public_names LOGIN NOINHERIT NOCREATEROLE'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spool_public_names')
\gexec

ALTER ROLE spool_public_names WITH LOGIN NOINHERIT NOCREATEROLE PASSWORD :'names_verifier';
ALTER ROLE spool_public_names SET statement_timeout = '60s';
ALTER ROLE spool_public_names SET idle_in_transaction_session_timeout = '60s';

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM spool_public_names;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM spool_public_names;
GRANT USAGE ON SCHEMA public TO spool_public_names;
GRANT SELECT (tenant_id, display_name) ON tenants TO spool_public_names;

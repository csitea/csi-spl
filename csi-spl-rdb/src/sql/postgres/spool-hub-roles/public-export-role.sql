-- public-export-role.sql - the public dataset export's LOGIN (spec 091 T004,
-- fence 1, spec 5.1). NOT a migration: it lives outside spool-hub/, so
-- `spool migrate` never reads it. psql runs it AS THE SCHEMA OWNER (cnf
-- hub.db_owner_user) from csi-spl-orc do_spl_public_export_role, with
--   :export_verifier  the password as a SCRAM-SHA-256 verifier, computed
--                     client side from the Secret Manager slot (cnf
--                     public_dataset.export_password_secret), so no clear-text
--                     password reaches the server, its logs or pg_stat_activity
-- then public-export-grants.sql (generated from the allow-list) gives it its
-- only privileges. hub-pg.tst.sh runs the same files on a throwaway Postgres.
--
-- The role: LOGIN, NOINHERIT, no CREATEDB / CREATEROLE, no memberships, owns
-- nothing (ownership would defeat FORCE RLS), never the operator scope's
-- friend: rdb 0126 pins it to one workspace with a RESTRICTIVE policy. rdb
-- 0126 creates it NOLOGIN (a policy names it); this file creates it only when
-- run before that migration. As in runtime-role.sql, Postgres 16 refuses to
-- let a role name SUPERUSER / BYPASSRLS / REPLICATION it does not hold, even
-- to turn them off, so they keep their default (off) and the caller reads
-- every flag back. Idempotent: a re-run only resets LOGIN, NOINHERIT and the
-- password.

SELECT 'CREATE ROLE spool_public_export NOLOGIN'
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spool_public_export')
\gexec

ALTER ROLE spool_public_export WITH LOGIN NOINHERIT NOCREATEROLE PASSWORD :'export_verifier';

-- A runaway export cannot hold a connection or the vacuum horizon (the
-- runtime login's ceilings, runtime-grants.sql); the export reads one
-- workspace, far below this.
ALTER ROLE spool_public_export SET statement_timeout = '300s';
ALTER ROLE spool_public_export SET idle_in_transaction_session_timeout = '60s';

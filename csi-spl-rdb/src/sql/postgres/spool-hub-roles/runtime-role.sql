-- runtime-role.sql - the hub's RUNTIME login (017 T029 / FR-SEC-014).
-- NOT a migration: it lives outside spool-hub/, so `spool migrate` never
-- reads it. psql runs it AS THE SCHEMA OWNER (cnf hub.db_owner_user), with
--   :runtime_role      the login to create (cnf hub.db_user)
--   :runtime_verifier  its password as a SCRAM-SHA-256 verifier, computed
--                      client side, so no clear-text password reaches the
--                      server, its logs or pg_stat_activity
-- Callers: csi-spl-orc do_spl_db_owner_split / do_spl_db_bootstrap (cloud),
-- csi-spl-api hub-pg.tst.sh (the same file against a throwaway Postgres).
--
-- Why the owner creates it, and not the other way round: Postgres 16 grants
-- the creator of a role ADMIN on it, recorded as granted by the bootstrap
-- superuser, so the creator can never drop that grant. Owner -> runtime is
-- the harmless direction. A runtime login holding ADMIN on the owner could
-- GRANT itself the owner and lift RLS.
--
-- The role: LOGIN, no CREATEROLE / CREATEDB, no memberships. Postgres 16
-- refuses to let a role name an attribute it does not hold itself (SUPERUSER,
-- BYPASSRLS, REPLICATION, and CREATEDB for an owner without it) even to turn
-- it off, so only CREATE names the two it may; the rest keep their default
-- (off). The callers read every flag back (do_spl_db_owner_split verify,
-- do_spl_db_rls_check).
-- Idempotent: an existing role only gets LOGIN and its password reset.

SELECT format('CREATE ROLE %I LOGIN NOCREATEDB NOCREATEROLE', :'runtime_role')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = :'runtime_role')
\gexec

ALTER ROLE :"runtime_role" WITH LOGIN PASSWORD :'runtime_verifier';

#!/bin/sh
# Postgres first-boot script for the standalone stack (mounted into the
# postgres image's /docker-entrypoint-initdb.d, runs once on an empty volume,
# as the bootstrap superuser). It creates the schema OWNER login and its
# database. The owner is NOT a superuser: a superuser skips every row level
# security policy (csi-spl-rdb 0014), so nothing the hub runs may be one.
# CREATEROLE, because the owner creates the hub's runtime login (hub
# init, spool-hub-roles/runtime-role.sql) - the same shape as the cloud.
set -eu
: "${SPOOL_OWNER_ROLE:?SPOOL_OWNER_ROLE must be set}"
: "${SPOOL_OWNER_PASSWORD:?SPOOL_OWNER_PASSWORD must be set}"
: "${SPOOL_DB_NAME:?SPOOL_DB_NAME must be set}"
psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
  -v owner="$SPOOL_OWNER_ROLE" -v pw="$SPOOL_OWNER_PASSWORD" -v db="$SPOOL_DB_NAME" <<'SQL'
CREATE ROLE :"owner" LOGIN PASSWORD :'pw' NOSUPERUSER NOBYPASSRLS CREATEROLE;
CREATE DATABASE :"db" OWNER :"owner" ENCODING 'UTF8' TEMPLATE template0;
SQL

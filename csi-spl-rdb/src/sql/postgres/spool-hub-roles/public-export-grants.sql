-- public-export-grants.sql - GENERATED, do not edit (spec 091 T004, fence 1).
-- Source: csi-spl-orc/cnf/public-dataset/allow-list.v1.yaml (sha256 da714e687bc2962a8fb445800c34ffbf1140821f59fe1421ad46713e1be7f020)
-- by csi-spl-orc ./run -a do_spl_public_export_grants_gen. A change to the
-- allow-list is a change to this file in the same commit (the store test
-- TestPublicExportGrantsEqualAllowList and public-export-grants-gen.tst.sh).
-- NOT a migration: psql runs it AS THE SCHEMA OWNER from
-- do_spl_public_export_role, after public-export-role.sql. Idempotent.
--
-- The export login holds column-level SELECT on exactly the public columns
-- of spec 4.1 and SELECT on public_export_workspace (fence 2, rdb 0126), so a
-- query naming any other column or table fails in Postgres itself. REVOKE ALL
-- on a table also revokes its column privileges.

REVOKE ALL ON ALL TABLES IN SCHEMA public FROM spool_public_export;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA public FROM spool_public_export;
GRANT USAGE ON SCHEMA public TO spool_public_export;

GRANT SELECT (tenant_id, display_name, created_at) ON tenants TO spool_public_export;
GRANT SELECT (channel_id, name, description, created_by, created_at) ON channels TO spool_public_export;
GRANT SELECT (msg_id, task_id, parent_task_id, channel, ts, from_id, to_id, kind, body, is_parent, received_at, expires_at) ON messages TO spool_public_export;
GRANT SELECT (human_id) ON humans TO spool_public_export;
GRANT SELECT (tenant_id, human_id, role, created_at) ON tenant_memberships TO spool_public_export;
GRANT SELECT ON public_export_workspace TO spool_public_export;

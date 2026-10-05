-- 0126_public_export_scope.sql - fence 2 of the public dataset export
-- (specs/091 T003, spec §5.2). Forward-only, additive, idempotent.
--
-- The export reads as its own role, spool_public_export, with
-- app.tenant_id set to the one exported workspace and app.rls_scope never
-- set. But the operator policy (rdb 0014) applies to every role, and any
-- login can set app.rls_scope for its own transaction, so "never set it"
-- alone would leave the export one statement away from every workspace.
-- This file closes that: a RESTRICTIVE policy, AND-ed with the permissive
-- ones, pins every exported tenant_id table to the one workspace named in
-- public_export_workspace, for this role only. The hub's roles are not this
-- role and see exactly what they saw before.
--
-- 1. The role spool_public_export, NOLOGIN, so a policy can name it. T004
--    (roles/public-export-role.sql) gives it LOGIN and its password. The
--    schema owner creates it (it holds CREATEROLE, as roles/runtime-role.sql
--    shows). Tests migrate several databases of one cluster at once, so a
--    concurrent create is tolerated.
-- 2. public_export_workspace: one row (one_row is the primary key and must
--    be true), the exported workspace's id. The column is workspace_id, not
--    tenant_id, so the per-workspace RLS gate (TestRLSPoliciesFailClosed)
--    and TestCrossTenantEveryTable do not read it as a workspace table. The
--    row is written by T004's action from cnf (env.public_dataset.
--    workspace_id), never here: no literal id. Row security is ENABLED
--    (not forced) with one SELECT policy, so the owner writes it and every
--    other role, the hub runtime login included (runtime-grants.sql grants
--    it DML on every table), reads it and writes nothing.
-- 3. RESTRICTIVE policy public_export_scope FOR SELECT TO
--    spool_public_export on tenants, channels, messages, tenant_memberships
--    (each ENABLE + FORCE since rdb 0014). With no row in
--    public_export_workspace the subquery is NULL and the role sees nothing:
--    fail closed.
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014). No personal
-- data, no secret. Catalog-only: no rewrite, a brief lock per table.

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'spool_public_export') THEN
        BEGIN
            CREATE ROLE spool_public_export NOLOGIN;
        EXCEPTION WHEN duplicate_object OR unique_violation THEN
            NULL; -- created by a concurrent migrator of another database
        END;
    END IF;
END
$$;

CREATE TABLE IF NOT EXISTS public_export_workspace (
    one_row      boolean PRIMARY KEY DEFAULT true CHECK (one_row),
    workspace_id text    NOT NULL REFERENCES tenants (tenant_id)
);

ALTER TABLE public_export_workspace ENABLE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS public_export_workspace_read ON public_export_workspace;
CREATE POLICY public_export_workspace_read ON public_export_workspace FOR SELECT USING (true);

REVOKE ALL ON public_export_workspace FROM PUBLIC;
GRANT SELECT ON public_export_workspace TO spool_public_export;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['tenants', 'channels', 'messages', 'tenant_memberships'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS public_export_scope ON %I', t);
        EXECUTE format($p$CREATE POLICY public_export_scope ON %I AS RESTRICTIVE
            FOR SELECT TO spool_public_export
            USING (tenant_id = (SELECT workspace_id FROM public_export_workspace))$p$, t);
    END LOOP;
END
$$;

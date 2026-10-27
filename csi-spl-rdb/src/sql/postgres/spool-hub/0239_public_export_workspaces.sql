-- 0239_public_export_workspaces.sql - fence 2 of the public dataset export
-- covers a LIST of workspaces (specs/091 section 4, SPL-3808). Forward-only,
-- idempotent.
--
-- Owner HUM-10 (t1 e2c0e6b4, msg c72b919b, poll answer afb3d81d "A"): the
-- export holds the data of the t1, spool and demo workspaces. rdb 0126 pinned
-- the export role to ONE workspace: public_export_workspace had one row (the
-- one_row primary key) and the RESTRICTIVE policy compared with "=" against it.
-- This file makes it a set:
--
-- 1. public_export_workspace: one_row goes (with it its primary key), and
--    workspace_id becomes the primary key, one row per exported workspace.
--    The rows are still written by do_spl_public_export_role from cnf
--    (env.public_dataset.workspace_ids), never here: no literal id. Grants,
--    row security and the read policy of 0126 stay as they are.
-- 2. RESTRICTIVE policy public_export_scope on tenants, channels, messages,
--    tenant_memberships: tenant_id IN (the set). With no row the role still
--    sees nothing: fail closed. The hub's roles are not this role and are
--    unaffected.
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014). No personal
-- data, no secret. Catalog-only: no rewrite, a brief lock per table.

ALTER TABLE public_export_workspace DROP COLUMN IF EXISTS one_row;

DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_constraint
                    WHERE conrelid = 'public_export_workspace'::regclass AND contype = 'p') THEN
        ALTER TABLE public_export_workspace ADD PRIMARY KEY (workspace_id);
    END IF;
END
$$;

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['tenants', 'channels', 'messages', 'tenant_memberships'] LOOP
        EXECUTE format('DROP POLICY IF EXISTS public_export_scope ON %I', t);
        EXECUTE format($p$CREATE POLICY public_export_scope ON %I AS RESTRICTIVE
            FOR SELECT TO spool_public_export
            USING (tenant_id IN (SELECT workspace_id FROM public_export_workspace))$p$, t);
    END LOOP;
END
$$;

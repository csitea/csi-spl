-- 0021_rls_fail_closed.sql — the tenant policy matches NOTHING when the
-- tenant setting is empty (specs/017 FR-SEC-014, CLE-3416). Forward-only.
--
-- 0014 compared tenant_id = current_setting('app.tenant_id', true). That
-- setting is NULL only on a connection that never set it: after the first
-- transaction-local set_config (inTenant, tenantBatch) it reads '' on that
-- pooled connection for good. '' = '' is TRUE, so an unscoped statement on a
-- used connection would see and write every tenant_id '' row. No such row can
-- be written today (tenants.tenant_id CHECK + the FKs), but the policy must
-- not lean on that: NULLIF turns '' into NULL, and NULL matches nothing.
--
-- Generic on purpose: every tenant_scope policy on a tenant_id table in this
-- schema, whichever migration created it (0014, 0015, 0016 and any later
-- table that copied the 0014 form before this file). store
-- TestRLSPoliciesFailClosed is the gate for every table, before and after.
--
-- Catalog-only (ALTER POLICY: no rewrite, no data change, brief lock). No
-- deploy order: a hub that sets the scope is unaffected, as '' was never a
-- tenant.

DO $$
DECLARE
    t text;
BEGIN
    FOR t IN
        SELECT p.tablename
        FROM pg_policies p
        JOIN information_schema.columns c
          ON c.table_schema = p.schemaname AND c.table_name = p.tablename AND c.column_name = 'tenant_id'
        WHERE p.schemaname = current_schema() AND p.policyname = 'tenant_scope'
        ORDER BY 1
    LOOP
        EXECUTE format($p$ALTER POLICY tenant_scope ON %I
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))$p$, t);
    END LOOP;
END
$$;

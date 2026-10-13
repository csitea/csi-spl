-- 0191_system_doc_tenant.sql - one spool-hub file system: the reserved
-- `system` tenant holds the repository docs, and every workspace reads them
-- (spec 137 T020, sections 4.1.2 and 4.2.2; panel Correction 1; owner HUM-10
-- t1 bed3ed0a msg 0e9d17b5 "one spool-hub file system with proper tenant
-- segregation"). Forward-only, additive.
--
--   tenants 'system'     the repo docs' tenant. It is no workspace: nobody
--                        signs in to it (suspended_at set, so every door
--                        answers 403 workspace_suspended), it has no host
--                        (its tenant_hosts row is dropped, so the reconciler
--                        provisions nothing) and no channels (the seeded
--                        four are dropped). Its root_pubkey is sha256 of a
--                        fixed text: 32 bytes whose private key, if they
--                        decode as a point at all, nobody holds, so no box
--                        pin or tenant-root signature verifies under it.
--                        The hub leaves it out of the operator workspace list
--                        and the all-tenant sweeps (store.SystemTenant).
--   <doc table>_select_repo
--                        a PERMISSIVE FOR SELECT policy per doctree table
--                        (0157, 0165): a row of tenant 'system' is readable in
--                        every scope. Writes are untouched: tenant_scope and
--                        operator_scope stay the only INSERT / UPDATE / DELETE
--                        policies, so a workspace session cannot write a
--                        system row (spec I2) and only the operator scope
--                        (the CI import, do_spl_doctree_import_md) can.
--
-- RLS stays on (0157 and 0165 ENABLE + FORCE it); this file adds policies.
-- Every hub list of a workspace's docs filters its own tenant_id, so system
-- rows never mix into a workspace's tree (store/wsdoc_hub.go).
-- Refused when a tenant 'system' exists that this file did not make: its
-- docs would turn readable to every workspace. 0 rows on dev and prd,
-- measured 2026-10-14 (do_spl_db_query).
-- DEPLOY ORDER: any. The tenant holds no doc until its import (spec 137
-- T030a), so a hub older than this file, whose doc list and search do not
-- filter the tenant, has nothing to show; the hub of this commit filters it.

SELECT set_config('app.rls_scope', 'operator', true);

DO $$
BEGIN
    PERFORM 1 FROM tenants
      WHERE tenant_id = 'system'
        AND root_pubkey <> sha256(convert_to('spool-hub system tenant: repository docs, no private key', 'UTF8'));
    IF FOUND THEN
        RAISE EXCEPTION '0191: a tenant ''system'' exists and is not the reserved one; rename it first'
            USING ERRCODE = 'unique_violation';
    END IF;
END $$;

INSERT INTO tenants (tenant_id, root_pubkey, billing_status, display_name, suspended_at)
VALUES ('system', sha256(convert_to('spool-hub system tenant: repository docs, no private key', 'UTF8')),
        'internal', 'Repository docs', now())
ON CONFLICT (tenant_id) DO NOTHING;

-- The tenants insert triggers queued a host and seeded the default channels.
DELETE FROM tenant_hosts WHERE tenant_id = 'system';
DELETE FROM channels WHERE tenant_id = 'system';

CREATE POLICY doc_node_select_repo ON workspace_doc_node
    FOR SELECT USING (tenant_id = 'system');
CREATE POLICY doc_select_repo ON workspace_doc
    FOR SELECT USING (tenant_id = 'system');
CREATE POLICY doc_item_select_repo ON workspace_doc_item
    FOR SELECT USING (tenant_id = 'system');
CREATE POLICY doc_rev_log_select_repo ON workspace_doc_rev_log
    FOR SELECT USING (tenant_id = 'system');

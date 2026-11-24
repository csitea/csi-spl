-- 0322_invoices_outlive_purge.sql - a private workspace's invoices outlive
-- its purge (spec 181 row B9 follow-up, SPL-6355). Forward-only, idempotent.
--
-- Owner HUM-10, t1 b12055b5, msg f872a556 (poll 48efd738, answer A): "Keep
-- them in the hub: the workspace is deleted, its invoices stay" (invoices
-- must be kept for years for bookkeeping).
--
-- The purge tick deletes a cancelled workspace with DELETE FROM tenants
-- (rdb 0319, store PurgeDueWorkspaces); rdb 0315's FK
-- (tenant_id REFERENCES tenants ON DELETE CASCADE) took every invoice with
-- it. An unpaid invoice already holds the purge, so it was the paid ones.
--
-- The FK is dropped, not turned into ON DELETE SET NULL: tenant_id is in
-- the primary key (tenant_id, month) and is the RLS key, so a NULL would
-- lose the invoice's identity and hide it from its workspace's scope. With
-- no FK the row keeps its tenant_id after the tenants row is gone, as the
-- cancellation tombstone (rdb 0319) and operator_audit (rdb 0115) do, and
-- the operator joins it to workspace_cancellations by that id. The invoice
-- carries no other workspace field to keep (rdb 0315). An invoice is still
-- only written through IssueInvoice, which reads the workspace's price plan
-- first (ErrNoPricePlan without one), so no invoice is born orphaned.
--
-- RLS: unchanged (rdb 0315). tenant_scope still shows a workspace only its
-- own rows, operator_scope every row, a purged workspace's included.
--
-- Live-data safety: drops one constraint; no row changes. The drop takes
-- ACCESS EXCLUSIVE on private_workspace_invoices and SHARE ROW EXCLUSIVE on
-- tenants until COMMIT, hence lock_timeout. No personal data, no secret.

SET LOCAL lock_timeout = '5s';

ALTER TABLE private_workspace_invoices DROP CONSTRAINT IF EXISTS private_workspace_invoices_tenant_id_fkey;

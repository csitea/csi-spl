-- 0004_tenant_manual.sql — specs/006 FR-001a. tenants is owned by 006.
-- Forward-only: 0001 created billing_status without 'manual' (an owner-made
-- renter tenant, do_spl_tenant_create, billed out of band until M2).
-- Quotas stay the plan's (cnf), not per-row columns (006 FR-008, OQ-006-1).

ALTER TABLE tenants DROP CONSTRAINT IF EXISTS tenants_billing_status_check;
ALTER TABLE tenants ADD CONSTRAINT tenants_billing_status_check
    CHECK (billing_status IN ('active', 'grace', 'unpaid', 'internal', 'manual'));

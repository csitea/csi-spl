-- 0314_workspace_orders.sql - the private-workspace order (spec 181 row B2,
-- section 4.1 step 4, gaps G3 and G12). Forward-only, additive.
--
-- Owner HUM-10, t1 b12055b5, msg 43573325, Q-18 C: "An order only, and the
-- workspace is created at once on submit; the invoice is paid by bank
-- transfer". The submit (POST /api/v1/checkout/private-workspace) writes, in
-- one transaction, the tenant, its biz_owner invite, the seat caps,
-- box_join_enabled on, the price plan (0302) and this row; no payment
-- provider is called.
--
-- workspace_orders is the provisioning order (G3) that row B8 takes to a
-- plan: one order per workspace (tenant_id is the key, so a replayed submit
-- finds the order it wrote and makes no second one). status is 'submitted'
-- only; B8 adds its states. No machine type column: B5's cnf map owns it.
-- The billing details are what the monthly invoice in arrears (B12) is
-- addressed to; no card, no provider reference.
--
-- RLS: the 0302 shape with the NULLIF guard; store TestRLSPoliciesFailClosed
-- reads it from the catalogue and TestCrossTenantEveryTable seeds it
-- (crosstenant_test.go). No channel_scope policy: a visitor never reads it.
--
-- Live-data safety: one new empty table (the FK takes SHARE ROW EXCLUSIVE on
-- tenants until COMMIT, hence lock_timeout). No existing table changes.
-- Runs under the operator RLS scope (spool migrate, rdb 0014). Personal
-- data: the buyer's email and billing address, the workspace's own; no
-- secret.

SET LOCAL lock_timeout = '5s';

CREATE TABLE workspace_orders (
    tenant_id       text        PRIMARY KEY REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    order_id        text        NOT NULL UNIQUE CHECK (order_id ~ '^wo_[a-z2-7]{26}$'),
    status          text        NOT NULL DEFAULT 'submitted' CHECK (status IN ('submitted')),
    seats_users     int         NOT NULL CHECK (seats_users >= 1),
    email           text        NOT NULL CHECK (email <> ''),
    billing_name    text        NOT NULL CHECK (billing_name <> ''),
    billing_address text        NOT NULL CHECK (billing_address <> ''),
    billing_country text        NOT NULL CHECK (billing_country ~ '^[A-Z]{2}$'),
    billing_vat_id  text        NULL,
    buyer_locale    text        NULL,
    created_at      timestamptz NOT NULL DEFAULT now()
);

ALTER TABLE workspace_orders ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_orders FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON workspace_orders
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON workspace_orders
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- 0256_income_invoices.sql - the workspace's invoiced income, one row per
-- invoice, read by Reporting -> Incomes (SPL-4697, spec 143 incomes.md;
-- owner HUM-10, csitea topic 450418ab msg e793f8d0: "we will add a new tab
-- i nthe reporting called incomes"). Forward-only.
--
--   income_invoices  one invoice the workspace's company was paid or is due:
--                    the month worked (period, always the 1st), the invoice
--                    number (unique per workspace, the import's upsert key),
--                    who pays, the dates, hours and unit price, and net + VAT
--                    = total in one currency. Written only through PUT
--                    /v1/operator/incomes (do_spl_incomes_import), never
--                    seeded: no figure lives in git.
--
-- The 3.2 tenant shape: tenant_id first (FK, ON DELETE CASCADE), ENABLE +
-- FORCE row level security, tenant_scope with the NULLIF guard (an unset or
-- '' workspace reads 0 rows and writes none), operator_scope. The runtime
-- grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql.
-- Live-data safety: one new empty table; its FK takes a SHARE ROW EXCLUSIVE
-- lock on tenants until COMMIT.
-- DEPLOY ORDER: apply BEFORE the hub that reads this table (wf 20 does).

CREATE TABLE income_invoices (
    tenant_id   text          NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    invoice_no  text          NOT NULL CHECK (length(btrim(invoice_no)) BETWEEN 1 AND 64),
    payer       text          NOT NULL CHECK (length(btrim(payer)) BETWEEN 1 AND 100),
    period      date          NOT NULL CHECK (extract(day FROM period) = 1),
    issue_date  date          NOT NULL,
    due_date    date          NOT NULL,
    hours       numeric(8,2)  NOT NULL CHECK (hours >= 0),
    unit_price  numeric(14,4) NOT NULL CHECK (unit_price >= 0),
    net         numeric(14,2) NOT NULL,
    vat_pct     numeric(5,2)  NOT NULL CHECK (vat_pct BETWEEN 0 AND 100),
    vat         numeric(14,2) NOT NULL,
    total       numeric(14,2) NOT NULL,
    currency    text          NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    source      text          NOT NULL DEFAULT 'import' CHECK (source IN ('import', 'email')),
    created_at  timestamptz   NOT NULL DEFAULT now(),
    updated_at  timestamptz   NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, invoice_no),
    CHECK (due_date >= issue_date),
    CHECK (net + vat = total)
);
CREATE INDEX income_invoices_period ON income_invoices (tenant_id, period);

-- RLS in the 0014/0021 shape, with the empty-setting guard (NULLIF, CLE-3416).
ALTER TABLE income_invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE income_invoices FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON income_invoices
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON income_invoices
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

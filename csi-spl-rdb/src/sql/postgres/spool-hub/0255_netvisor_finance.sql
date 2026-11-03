-- 0255_netvisor_finance.sql - the hub tables for Netvisor finance data
-- (spec 125 v0.1 sections 5.2 and 7, build row B4, SPL-4721; owner HUM-10,
-- topic fc0119cd). Forward-only, additive. The spec names "<next>": the next
-- prefix on master when it lands (renumbered on rebase).
--
--   netvisor_settings        one row per workspace: owner_human_id is the
--                     ONE human who reads this workspace's Netvisor data
--                     (C7: data, never a code literal), env the Netvisor
--                     company it is fetched from (test | prd), and the
--                     bookkeeping account numbers of the forecast (the bank
--                     account, C3; the VAT and tax liability accounts) and
--                     the spec-123 vendor exclusion list (section 4.2).
--   netvisor_snapshots       one row per fetch: as_of, month_end and the
--                     newest booked bank voucher date (section 3.1).
--   netvisor_forecast_items  the month-end cash forecast terms of one
--                     snapshot (section 3.1): category, sign, amount, due
--                     date, the overdue and approved splits.
--   netvisor_card_cost_lines the card cost lines of one snapshot (section
--                     4): month, route, vendor, cost type (account), cost
--                     centre (dimension), amount, and the exclusion mark.
--
-- RLS (C7, C8): the 0240 tenant_scope on all four tables, plus a RESTRICTIVE
-- owner_scope: a row passes only when its owner_human_id equals the
-- transaction-local app.human_id (store inNetvisorOwner, set from the
-- authenticated human session only) and, for the three data tables, that
-- human is the workspace's owner in netvisor_settings NOW: after the
-- operator moves the owner, the old owner reads and writes nothing, and the
-- new one does not read the old owner's snapshots. Another member, an admin, an agent, a
-- statement with the tenant alone and another workspace read and write 0
-- rows. NO operator_scope policy (the workspace_vendor_keys shape of rdb
-- 0174): the operator scope, the ops psql and the Reporting SQL tab read 0
-- rows. The one other way in is app.rls_scope = 'netvisor_ingest' (store
-- inNetvisorIngest, the B5 operator ingest): it reads and writes
-- netvisor_settings only, to set the owner and to learn whom a snapshot
-- belongs to; the snapshot itself is then written in that owner's scope.
-- A child row carries its snapshot's owner under a composite FK, so a line
-- can never be filed under another human than its snapshot.
--
-- A tenant delete cascades all four tables (FK ON DELETE CASCADE; an RI
-- action is not subject to RLS). Backups: a pg_dump under the operator scope
-- holds no row of these tables; the nightly sync rebuilds the snapshots and
-- the owner re-enters the settings (Cloud SQL backups hold everything).
-- Store tests: netvisor_test.go (TestNetvisorStoreRLS), rls_test.go,
-- crosstenant_test.go, rls_failclosed_test.go (from the catalogue). Runtime
-- grants: the default privileges of spool-hub-roles/runtime-grants.sql.
--
-- Live-data safety: four new empty tables; the FKs take a SHARE ROW
-- EXCLUSIVE lock on tenants until COMMIT, hence lock_timeout. No running
-- hub reads them (B5 does, later). DEPLOY ORDER: wf 20 applies this before
-- the image that reads it. No figure, account number or id is seeded here.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS netvisor_settings (
    tenant_id         text        NOT NULL PRIMARY KEY REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    owner_human_id    text        NOT NULL CHECK (owner_human_id ~ '^HUM-[0-9]+$'),
    env               text        NOT NULL DEFAULT 'test' CHECK (env IN ('test', 'prd')),
    bank_account      text        NULL CHECK (bank_account ~ '^[0-9]{1,12}$'),
    vat_accounts      text[]      NOT NULL DEFAULT '{}' CHECK (cardinality(vat_accounts) <= 32
                          AND array_to_string(vat_accounts, ',') ~ '^([0-9]{1,12}(,[0-9]{1,12})*)?$'),
    tax_accounts      text[]      NOT NULL DEFAULT '{}' CHECK (cardinality(tax_accounts) <= 32
                          AND array_to_string(tax_accounts, ',') ~ '^([0-9]{1,12}(,[0-9]{1,12})*)?$'),
    vendor_exclusions text[]      NOT NULL DEFAULT '{}' CHECK (cardinality(vendor_exclusions) <= 200
                          AND length(array_to_string(vendor_exclusions, '')) <= 20000),
    updated_by        text        NOT NULL CHECK (length(updated_by) BETWEEN 1 AND 200),
    updated_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS netvisor_snapshots (
    tenant_id                text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    snapshot_id              uuid        NOT NULL,
    owner_human_id           text        NOT NULL CHECK (owner_human_id ~ '^HUM-[0-9]+$'),
    env                      text        NOT NULL CHECK (env IN ('test', 'prd')),
    as_of                    date        NOT NULL,
    month_end                date        NOT NULL,
    newest_bank_voucher_date date        NULL,
    fetched_at               timestamptz NOT NULL,
    created_at               timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, snapshot_id),
    CONSTRAINT uq_netvisor_snapshots_owner UNIQUE (tenant_id, snapshot_id, owner_human_id),
    CONSTRAINT ck_netvisor_snapshots_month_end CHECK (month_end >= as_of)
);
CREATE INDEX IF NOT EXISTS ix_netvisor_snapshots_latest
    ON netvisor_snapshots (tenant_id, owner_human_id, env, fetched_at DESC);

CREATE TABLE IF NOT EXISTS netvisor_forecast_items (
    tenant_id      text          NOT NULL,
    snapshot_id    uuid          NOT NULL,
    owner_human_id text          NOT NULL,
    item_no        integer       NOT NULL CHECK (item_no >= 0),
    category       text          NOT NULL CHECK (category IN ('bank_balance', 'receivable', 'payable', 'payment',
                                     'payroll', 'vat', 'tax', 'contract')),
    sign           smallint      NOT NULL CHECK (sign IN (-1, 1)),
    amount         numeric(18,2) NOT NULL,
    currency       text          NOT NULL DEFAULT 'EUR' CHECK (currency ~ '^[A-Z]{3}$'),
    due_date       date          NULL,
    overdue        boolean       NOT NULL DEFAULT false,
    approved       boolean       NULL,
    label          text          NOT NULL DEFAULT '' CHECK (length(label) <= 200),
    PRIMARY KEY (tenant_id, snapshot_id, item_no),
    CONSTRAINT fk_netvisor_forecast_items_snapshot FOREIGN KEY (tenant_id, snapshot_id, owner_human_id)
        REFERENCES netvisor_snapshots (tenant_id, snapshot_id, owner_human_id) ON DELETE CASCADE
);

CREATE TABLE IF NOT EXISTS netvisor_card_cost_lines (
    tenant_id      text          NOT NULL,
    snapshot_id    uuid          NOT NULL,
    owner_human_id text          NOT NULL,
    line_no        integer       NOT NULL CHECK (line_no >= 0),
    month          date          NOT NULL CHECK (month = date_trunc('month', month)::date),
    route          text          NOT NULL CHECK (route IN ('credit_einvoice', 'debit_ledger', 'expense_report')),
    vendor         text          NOT NULL DEFAULT '' CHECK (length(vendor) <= 200),
    account_number text          NOT NULL CHECK (account_number ~ '^[0-9]{1,12}$'),
    account_name   text          NOT NULL DEFAULT '' CHECK (length(account_name) <= 200),
    dimension      text          NOT NULL DEFAULT '' CHECK (length(dimension) <= 200),
    dimension_item text          NOT NULL DEFAULT '' CHECK (length(dimension_item) <= 200),
    amount         numeric(18,2) NOT NULL,
    currency       text          NOT NULL DEFAULT 'EUR' CHECK (currency ~ '^[A-Z]{3}$'),
    vat_code       text          NOT NULL DEFAULT '' CHECK (length(vat_code) <= 32),
    excluded       boolean       NOT NULL DEFAULT false,
    PRIMARY KEY (tenant_id, snapshot_id, line_no),
    CONSTRAINT fk_netvisor_card_cost_lines_snapshot FOREIGN KEY (tenant_id, snapshot_id, owner_human_id)
        REFERENCES netvisor_snapshots (tenant_id, snapshot_id, owner_human_id) ON DELETE CASCADE
);

DO $$
DECLARE
    t text;
BEGIN
    FOREACH t IN ARRAY ARRAY['netvisor_settings', 'netvisor_snapshots', 'netvisor_forecast_items',
                             'netvisor_card_cost_lines'] LOOP
        EXECUTE format('ALTER TABLE %I ENABLE ROW LEVEL SECURITY', t);
        EXECUTE format('ALTER TABLE %I FORCE ROW LEVEL SECURITY', t);
        EXECUTE format('DROP POLICY IF EXISTS tenant_scope ON %I', t);
        EXECUTE format($p$CREATE POLICY tenant_scope ON %I
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))$p$, t);
        EXECUTE format('DROP POLICY IF EXISTS owner_scope ON %I', t);
        EXECUTE format($p$CREATE POLICY owner_scope ON %1$I AS RESTRICTIVE
            USING (%2$s) WITH CHECK (%2$s)$p$, t,
            CASE WHEN t = 'netvisor_settings'
                 THEN $c$owner_human_id = NULLIF(current_setting('app.human_id', true), '')
                     OR current_setting('app.rls_scope', true) = 'netvisor_ingest'$c$
                 ELSE format($c$owner_human_id = NULLIF(current_setting('app.human_id', true), '')
                     AND EXISTS (SELECT 1 FROM netvisor_settings s WHERE s.tenant_id = %1$I.tenant_id
                                 AND s.owner_human_id = %1$I.owner_human_id)$c$, t) END);
    END LOOP;
END
$$;

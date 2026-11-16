-- 0286_hr_worker_side.sql - the worker side of a person's month (SPL-5433
-- step d, spec 123 section 16.5; owner HUM-10, t1 2d974709, poll 2ff12c21
-- answer 4 B: the hub computes the employer side AND the worker side, a typed
-- payslip value wins and a difference is flagged). Forward-only, additive.
--
--   hr_worker_rates  the employee's share of one statutory contribution for
--                    one year and one age band: tyel_employee (TyEL, by the
--                    person's age that year) and unemployment_employee. The
--                    hub computes gross x rate_pct / 100 for an employee or
--                    an hourly worker whose age (year - birth_year) is in
--                    age_from..age_to. No row = no share computed.
--   hr_tax_cards     one person's tax card for one year, typed by hand from
--                    the card: base_pct up to income_limit of the year's
--                    income, extra_pct above it. The hub keeps the running
--                    year-to-date gross, so it knows when extra_pct applies.
--   hr_payslips      the worker-side values of one person's payslip for one
--                    month and currency, each NULL when the payslip does not
--                    carry it. A typed value wins over the computed one; a
--                    difference above a cent is flagged.
--
-- The worker side is part of the gross: it is shown only in the accountant's
-- payslip check and never added to a cost line, report or total (owner Q5 A:
-- management reporting). Tax cards and payslips are personal: like
-- hr_person_names (rdb 0280) their policy asks app.costs_names = 'on' as well
-- as the operator scope, which the hub sets only for a costs.write caller.
-- Live-data safety: three new tables, no row seeded, no personal data.
-- DEPLOY ORDER: apply BEFORE the hub that reads it (wf 20 does).

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS hr_worker_rates (
    year        integer       NOT NULL CHECK (year BETWEEN 2000 AND 2100),
    kind        text          NOT NULL CHECK (kind IN ('tyel_employee', 'unemployment_employee')),
    age_from    smallint      NOT NULL CHECK (age_from BETWEEN 0 AND 120),
    age_to      smallint      NOT NULL CHECK (age_to BETWEEN 0 AND 120),
    rate_pct    numeric(7, 4) NOT NULL CHECK (rate_pct >= 0 AND rate_pct < 100),
    source      text          NOT NULL DEFAULT '' CHECK (length(source) <= 200),
    set_by      text          NOT NULL CHECK (length(set_by) BETWEEN 1 AND 200),
    set_at      timestamptz   NOT NULL DEFAULT now(),
    PRIMARY KEY (year, kind, age_from),
    CHECK (age_to >= age_from)
);

CREATE TABLE IF NOT EXISTS hr_tax_cards (
    person_id     uuid           NOT NULL REFERENCES hr_people (id) ON DELETE CASCADE,
    year          integer        NOT NULL CHECK (year BETWEEN 2000 AND 2100),
    base_pct      numeric(5, 2)  NOT NULL CHECK (base_pct >= 0 AND base_pct < 100),
    extra_pct     numeric(5, 2)  NOT NULL CHECK (extra_pct >= 0 AND extra_pct < 100),
    income_limit  numeric(12, 2) NOT NULL CHECK (income_limit >= 0),
    source        text           NOT NULL DEFAULT '' CHECK (length(source) <= 200),
    set_by        text           NOT NULL CHECK (length(set_by) BETWEEN 1 AND 200),
    set_at        timestamptz    NOT NULL DEFAULT now(),
    PRIMARY KEY (person_id, year)
);

CREATE TABLE IF NOT EXISTS hr_payslips (
    person_id              uuid           NOT NULL REFERENCES hr_people (id) ON DELETE CASCADE,
    month                  date           NOT NULL CHECK (extract(day FROM month) = 1),
    currency               text           NOT NULL CHECK (currency ~ '^[A-Z]{3}$'),
    tyel_employee          numeric(12, 2) CHECK (tyel_employee >= 0),
    unemployment_employee  numeric(12, 2) CHECK (unemployment_employee >= 0),
    tax_withheld           numeric(12, 2) CHECK (tax_withheld >= 0),
    net_pay                numeric(12, 2),
    set_by                 text           NOT NULL CHECK (length(set_by) BETWEEN 1 AND 200),
    set_at                 timestamptz    NOT NULL DEFAULT now(),
    PRIMARY KEY (person_id, month, currency)
);

ALTER TABLE hr_worker_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE hr_worker_rates FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS operator_scope ON hr_worker_rates;
CREATE POLICY operator_scope ON hr_worker_rates
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE hr_tax_cards ENABLE ROW LEVEL SECURITY;
ALTER TABLE hr_tax_cards FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS operator_names_scope ON hr_tax_cards;
CREATE POLICY operator_names_scope ON hr_tax_cards
    USING (current_setting('app.rls_scope', true) = 'operator' AND current_setting('app.costs_names', true) = 'on')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator' AND current_setting('app.costs_names', true) = 'on');

ALTER TABLE hr_payslips ENABLE ROW LEVEL SECURITY;
ALTER TABLE hr_payslips FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS operator_names_scope ON hr_payslips;
CREATE POLICY operator_names_scope ON hr_payslips
    USING (current_setting('app.rls_scope', true) = 'operator' AND current_setting('app.costs_names', true) = 'on')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator' AND current_setting('app.costs_names', true) = 'on');

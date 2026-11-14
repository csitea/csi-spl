-- 0284_hr_rates.sql - the employer side's rates per year (SPL-5433 step c,
-- spec 123 section 16.4; owner HUM-10, t1 2d974709, poll 2ff12c21 answer 4 B:
-- the hub computes the employer side, a typed payslip value wins and a
-- difference is flagged). Forward-only, additive.
--
--   hr_rates  one employer contribution's rate for one year: the hub computes
--             gross x rate_pct / 100 for each person whose employment type is
--             in applies_to, per month of that year. component is an
--             hr_cost_components row of the employer_contributions group (the
--             hub refuses yel, which is not a share of gross). source says
--             where the accountant read the rate (e.g. "pension insurer's
--             2026 letter"). No row = nothing is computed for that component.
--
-- The rates live here, not in csi-spl-cnf: a cnf value reaches the hub only
-- as a Cloud Run env var through terraform (an owner's go per change), and
-- the accountant sets the year's rates once a year from the insurer's and the
-- Tax Administration's letters. Operator scope only, like cost_entries (rdb
-- 0245). Live-data safety: one new table, no row seeded, no personal data.
-- DEPLOY ORDER: apply BEFORE the hub that reads it (wf 20 does).

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS hr_rates (
    year        integer       NOT NULL CHECK (year BETWEEN 2000 AND 2100),
    component   text          NOT NULL REFERENCES hr_cost_components (component),
    rate_pct    numeric(7, 4) NOT NULL CHECK (rate_pct >= 0 AND rate_pct < 100),
    applies_to  text[]        NOT NULL DEFAULT '{employee,hourly}'
                              CHECK (cardinality(applies_to) BETWEEN 1 AND 4
                                     AND applies_to <@ ARRAY['employee', 'hourly', 'owner_management', 'contractor']),
    source      text          NOT NULL DEFAULT '' CHECK (length(source) <= 200),
    set_by      text          NOT NULL CHECK (length(set_by) BETWEEN 1 AND 200),
    set_at      timestamptz   NOT NULL DEFAULT now(),
    PRIMARY KEY (year, component)
);

ALTER TABLE hr_rates ENABLE ROW LEVEL SECURITY;
ALTER TABLE hr_rates FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS operator_scope ON hr_rates;
CREATE POLICY operator_scope ON hr_rates
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

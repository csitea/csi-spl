-- 0280_hr_people_and_periods.sql - human costs per person, component and
-- month, with the month lock (SPL-5433, spec 123 section 16.2; owner HUM-10,
-- t1 2d974709, polls a82c0089 and 2ff12c21 answered 2026-11-13: one line per
-- person; a month closes by itself on the 6th of the next month; the real
-- name stored, readable only by the accountants; payroll on both sides is
-- computed later, steps c and d). Forward-only, additive.
--
--   hr_cost_components  the components an hr line books to, in their group
--                       (HUM-24's 8 groups, csitea #csi-fina ba50f507). A
--                       country or a collective agreement adds ROWS here, no
--                       code. default_account is the ledger account a later
--                       import maps to ('' = none yet).
--   hr_people           one person the accountant books costs for, by a code
--                       (E-01): department, employment type, birth year (the
--                       employee's pension share depends on age, step d).
--                       No name here.
--   hr_person_names     the real name, one row per person, readable only in
--                       the operator scope AND with app.costs_names = 'on',
--                       which the store sets only for a costs.write caller.
--   cost_entries        + person_id (an hr line's person; null = the
--                       organisation's), component, source (where the figure
--                       comes from, e.g. "payslip 2026-10"), account (the
--                       ledger account), period_kind (month, or year for a
--                       yearly total booked as one line; period is then the
--                       year's January), corrects_period (a late correction:
--                       the closed month it corrects).
--   cost_periods        the month lock's explicit state. A month with no row
--                       is closed from the 6th of the next month 00:00
--                       Europe/Helsinki on (the hub computes it, no cron); a
--                       row says otherwise: closed_at null = reopened by the
--                       operator admin, with the reason and who.
--
-- Operator scope only, like cost_entries (rdb 0245). Live-data safety: three
-- new tables, five nullable / defaulted columns on cost_entries (existing
-- rows read as the organisation's monthly lines, no component), seed rows in
-- hr_cost_components only. No personal data, no secret.
-- DEPLOY ORDER: apply BEFORE the hub that reads these (wf 20 does).

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS hr_cost_components (
    component        text    PRIMARY KEY CHECK (component ~ '^[a-z][a-z0-9_]{1,59}$'),
    grp              text    NOT NULL CHECK (grp IN ('salaries_wages', 'employer_contributions', 'working_time_allowances',
                                 'bonuses_incentives', 'leave_absence', 'benefits_insurance', 'training_recruitment', 'transport_meals')),
    label            text    NOT NULL CHECK (length(label) BETWEEN 1 AND 100),
    default_account  text    NOT NULL DEFAULT '' CHECK (length(default_account) <= 20),
    sort_order       integer NOT NULL DEFAULT 0
);

INSERT INTO hr_cost_components (component, grp, label, sort_order) VALUES
    ('monthly_salary',          'salaries_wages',          'Monthly salary', 10),
    ('hourly_pay',              'salaries_wages',          'Hourly pay (hours x rate)', 11),
    ('owner_salary',            'salaries_wages',          'Owner''s salary', 12),
    ('base_pay',                'salaries_wages',          'Base pay', 13),
    ('tyel_employer',           'employer_contributions',  'TyEL, employer''s share', 20),
    ('yel',                     'employer_contributions',  'YEL, entrepreneur''s pension', 21),
    ('unemployment_employer',   'employer_contributions',  'Unemployment insurance, employer''s share', 22),
    ('health_insurance',        'employer_contributions',  'Health insurance contribution', 23),
    ('accident_insurance',      'employer_contributions',  'Accident insurance', 24),
    ('group_life_insurance',    'employer_contributions',  'Group life insurance', 25),
    ('overtime',                'working_time_allowances', 'Overtime', 30),
    ('evening_night',           'working_time_allowances', 'Evening and night allowance', 31),
    ('sunday_holiday',          'working_time_allowances', 'Sunday and holiday allowance', 32),
    ('shift',                   'working_time_allowances', 'Shift allowance', 33),
    ('bonus',                   'bonuses_incentives',      'Bonus or incentive', 40),
    ('annual_leave',            'leave_absence',           'Annual leave pay', 50),
    ('holiday_bonus',           'leave_absence',           'Holiday bonus (lomaraha)', 51),
    ('sick_leave',              'leave_absence',           'Sick leave pay', 52),
    ('other_paid_absence',      'leave_absence',           'Other paid absence', 53),
    ('occupational_healthcare', 'benefits_insurance',      'Occupational healthcare', 60),
    ('voluntary_insurance',     'benefits_insurance',      'Voluntary personal insurance', 61),
    ('lunch_benefit',           'benefits_insurance',      'Lunch benefit', 62),
    ('sports_benefit',          'benefits_insurance',      'Sports and culture benefit', 63),
    ('training',                'training_recruitment',    'Training', 70),
    ('recruitment',             'training_recruitment',    'Recruitment', 71),
    ('business_travel',         'transport_meals',         'Business travel', 80),
    ('mileage',                 'transport_meals',         'Mileage allowance', 81),
    ('company_car',             'transport_meals',         'Company car', 82),
    ('meals',                   'transport_meals',         'Meal allowance', 83)
ON CONFLICT DO NOTHING;

CREATE TABLE IF NOT EXISTS hr_people (
    id               uuid        PRIMARY KEY,
    code             text        NOT NULL UNIQUE CHECK (code ~ '^[A-Z]{1,3}-[0-9]{2,4}$'),
    department       text        NOT NULL DEFAULT '' CHECK (length(department) <= 100),
    employment_type  text        NOT NULL CHECK (employment_type IN ('employee', 'hourly', 'owner_management', 'contractor')),
    birth_year       integer     CHECK (birth_year BETWEEN 1900 AND 2100),
    left_on          date,
    created_by       text        NOT NULL CHECK (length(created_by) BETWEEN 1 AND 200),
    created_at       timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS hr_person_names (
    person_id  uuid PRIMARY KEY REFERENCES hr_people (id) ON DELETE CASCADE,
    name       text NOT NULL CHECK (length(name) BETWEEN 1 AND 200)
);

ALTER TABLE cost_entries
    ADD COLUMN IF NOT EXISTS person_id       uuid REFERENCES hr_people (id) ON DELETE RESTRICT,
    ADD COLUMN IF NOT EXISTS component       text REFERENCES hr_cost_components (component),
    ADD COLUMN IF NOT EXISTS source          text NOT NULL DEFAULT '' CHECK (length(source) <= 200),
    ADD COLUMN IF NOT EXISTS account         text NOT NULL DEFAULT '' CHECK (length(account) <= 20),
    ADD COLUMN IF NOT EXISTS period_kind     text NOT NULL DEFAULT 'month' CHECK (period_kind IN ('month', 'year')),
    ADD COLUMN IF NOT EXISTS corrects_period date CHECK (corrects_period IS NULL OR extract(day FROM corrects_period) = 1);
CREATE INDEX IF NOT EXISTS cost_entries_person ON cost_entries (person_id) WHERE person_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS cost_periods (
    period         date        PRIMARY KEY CHECK (extract(day FROM period) = 1),
    closed_at      timestamptz,
    closed_by      text        NOT NULL DEFAULT '' CHECK (length(closed_by) <= 200),
    reopened_at    timestamptz,
    reopened_by    text        NOT NULL DEFAULT '' CHECK (length(reopened_by) <= 200),
    reopen_reason  text        NOT NULL DEFAULT '' CHECK (length(reopen_reason) <= 500)
);

ALTER TABLE hr_cost_components ENABLE ROW LEVEL SECURITY;
ALTER TABLE hr_cost_components FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS operator_scope ON hr_cost_components;
CREATE POLICY operator_scope ON hr_cost_components
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE hr_people ENABLE ROW LEVEL SECURITY;
ALTER TABLE hr_people FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS operator_scope ON hr_people;
CREATE POLICY operator_scope ON hr_people
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE hr_person_names ENABLE ROW LEVEL SECURITY;
ALTER TABLE hr_person_names FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS operator_names_scope ON hr_person_names;
CREATE POLICY operator_names_scope ON hr_person_names
    USING (current_setting('app.rls_scope', true) = 'operator' AND current_setting('app.costs_names', true) = 'on')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator' AND current_setting('app.costs_names', true) = 'on');

ALTER TABLE cost_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE cost_periods FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS operator_scope ON cost_periods;
CREATE POLICY operator_scope ON cost_periods
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

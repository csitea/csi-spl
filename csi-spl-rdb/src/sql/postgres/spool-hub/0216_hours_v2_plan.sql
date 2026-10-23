-- 0215_hours_v2_plan.sql - hours tracking v2: the people and plan tables
-- (spec 107 v2.2, build row T021; FR-14, FR-16, FR-18, FR-22, FR-29, FR-37).
-- Forward-only, additive. Owner HUM-10, csitea topic 55a2d6c2, msg 81ed4911.
--
--   hours_standard_days  a person's standard-day override from its date on
--                        (FR-14): seven weekday minutes, Monday first; a
--                        weekday at 0 is not a working day, all 0 = no
--                        standard day. overtime_weekly_minutes is the
--                        person's weekly overtime threshold (FR-28, read by
--                        T026), NULL = the workspace's. No row = the
--                        workspace's hours.standard_day_minutes.
--   hours_jobs           a job, the target job:<job_id> (FR-18): name, site,
--                        an optional linked topic, the quote in minutes, open
--                        or closed. The hub closes a job, it never deletes one.
--   hours_plan           the shift plan (FR-16): per (member, day) up to two
--                        rows (slot 1..2), the job, the shift's start and end,
--                        explicit (written by a foreman or the office) and the
--                        crew the member was in when it was written. The
--                        inherited read (no row on a day) is the store's (T027).
--   hours_crews          a named crew (FR-22).
--   hours_crew_members   who is in a crew, as worker or foreman, from a day to
--                        a day (NULL = open). A worker is in at most one crew
--                        at a time: one open worker row per member (partial
--                        unique index); a foreman may lead several crews.
--   hours_holidays       the public-holiday calendar (FR-29): (region, day),
--                        a name and optional minutes for a part day. region ''
--                        is the workspace's calendar for members with none.
--
-- No money (FR-19): no rate, amount or cost column. Each table in the 3.2
-- shape (FR-37): tenant_id first, ENABLE + FORCE RLS, tenant_scope with the
-- NULLIF guard, operator_scope (rls_failclosed_test's catalogue gate). The
-- plan rows of a job and the member rows of a crew go with it (ON DELETE
-- CASCADE), so a tenant delete passes in any order.
--
-- Live-data safety: six new, empty tables; no existing table is touched.
-- Runtime grants: the default privileges of spool-hub-roles/runtime-grants.sql.
-- Runs under the operator RLS scope (spool migrate, rdb 0014). The running
-- image reads none of this, so the file applies before the image that does
-- (wf 20). No personal data beyond member ids, no secret.

CREATE TABLE hours_standard_days (
    tenant_id               text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    member_id               text        NOT NULL,
    effective_from          date        NOT NULL,
    mon_minutes             integer     NOT NULL CHECK (mon_minutes BETWEEN 0 AND 1440),
    tue_minutes             integer     NOT NULL CHECK (tue_minutes BETWEEN 0 AND 1440),
    wed_minutes             integer     NOT NULL CHECK (wed_minutes BETWEEN 0 AND 1440),
    thu_minutes             integer     NOT NULL CHECK (thu_minutes BETWEEN 0 AND 1440),
    fri_minutes             integer     NOT NULL CHECK (fri_minutes BETWEEN 0 AND 1440),
    sat_minutes             integer     NOT NULL CHECK (sat_minutes BETWEEN 0 AND 1440),
    sun_minutes             integer     NOT NULL CHECK (sun_minutes BETWEEN 0 AND 1440),
    overtime_weekly_minutes integer     NULL CHECK (overtime_weekly_minutes BETWEEN 0 AND 10080),
    updated_by              text        NOT NULL,
    updated_at              timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, member_id, effective_from)
);

CREATE TABLE hours_jobs (
    tenant_id     text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    job_id        text        NOT NULL CHECK (job_id ~ '^[A-Za-z0-9._-]{1,64}$'),
    name          text        NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    site          text        NOT NULL DEFAULT '' CHECK (length(site) <= 500),
    task_id       text        NULL CHECK (length(task_id) BETWEEN 1 AND 200),
    quote_minutes integer     NULL CHECK (quote_minutes >= 0),
    state         text        NOT NULL DEFAULT 'open' CHECK (state IN ('open', 'closed')),
    updated_by    text        NOT NULL,
    updated_at    timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, job_id)
);

CREATE TABLE hours_crews (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    crew_id    text        NOT NULL CHECK (crew_id ~ '^[A-Za-z0-9._-]{1,64}$'),
    name       text        NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    updated_by text        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, crew_id)
);

CREATE TABLE hours_crew_members (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    crew_id    text        NOT NULL,
    member_id  text        NOT NULL,
    role       text        NOT NULL CHECK (role IN ('worker', 'foreman')),
    from_day   date        NOT NULL,
    to_day     date        NULL,
    updated_by text        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, crew_id, member_id, role, from_day),
    CHECK (to_day IS NULL OR to_day >= from_day),
    FOREIGN KEY (tenant_id, crew_id) REFERENCES hours_crews (tenant_id, crew_id) ON DELETE CASCADE
);
-- FR-22: a worker is in at most one crew at a time.
CREATE UNIQUE INDEX hours_crew_members_one_open_worker ON hours_crew_members (tenant_id, member_id)
    WHERE role = 'worker' AND to_day IS NULL;
-- HoursCrewOf(member, day) and HoursLeads(foreman, member, day) (T028).
CREATE INDEX hours_crew_members_member ON hours_crew_members (tenant_id, member_id, from_day);

CREATE TABLE hours_plan (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    member_id  text        NOT NULL,
    day        date        NOT NULL,
    slot       smallint    NOT NULL CHECK (slot BETWEEN 1 AND 2),
    job_id     text        NOT NULL,
    start_at   timestamptz NOT NULL CHECK (start_at = date_trunc('minute', start_at, 'UTC')),
    end_at     timestamptz NOT NULL CHECK (end_at = date_trunc('minute', end_at, 'UTC')),
    explicit   boolean     NOT NULL DEFAULT true,
    crew_id    text        NULL,
    updated_by text        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, member_id, day, slot),
    CHECK (end_at > start_at AND end_at - start_at <= interval '1440 minutes'),
    FOREIGN KEY (tenant_id, job_id) REFERENCES hours_jobs (tenant_id, job_id) ON DELETE CASCADE
);
-- A crew's or the workspace's week (the plan screen, FR-38).
CREATE INDEX hours_plan_day ON hours_plan (tenant_id, day);
-- The job's FK cascade and its planned rows.
CREATE INDEX hours_plan_job ON hours_plan (tenant_id, job_id);

CREATE TABLE hours_holidays (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    region     text        NOT NULL DEFAULT '' CHECK (length(region) <= 64),
    day        date        NOT NULL,
    name       text        NOT NULL CHECK (length(btrim(name)) BETWEEN 1 AND 200),
    minutes    integer     NULL CHECK (minutes BETWEEN 1 AND 1440),
    updated_by text        NOT NULL,
    updated_at timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, region, day)
);

-- RLS in the 0014/0021 shape, with the empty-setting guard (NULLIF, CLE-3416).
ALTER TABLE hours_standard_days ENABLE ROW LEVEL SECURITY;
ALTER TABLE hours_standard_days FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON hours_standard_days
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON hours_standard_days
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE hours_jobs ENABLE ROW LEVEL SECURITY;
ALTER TABLE hours_jobs FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON hours_jobs
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON hours_jobs
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE hours_crews ENABLE ROW LEVEL SECURITY;
ALTER TABLE hours_crews FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON hours_crews
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON hours_crews
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE hours_crew_members ENABLE ROW LEVEL SECURITY;
ALTER TABLE hours_crew_members FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON hours_crew_members
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON hours_crew_members
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE hours_plan ENABLE ROW LEVEL SECURITY;
ALTER TABLE hours_plan FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON hours_plan
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON hours_plan
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE hours_holidays ENABLE ROW LEVEL SECURITY;
ALTER TABLE hours_holidays FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON hours_holidays
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON hours_holidays
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- 0151_hours.sql - hours tracking (spec 107 v1.0, T002; sections 3.2, 3.3,
-- 6.1). Forward-only. Owner HUM-10, t1 ef217164.
--
--   hours_minutes  the only activity record: one row per (member, minute)
--                  the member was at work, with the target it went to and
--                  its source (a post overrides a tab, spec 1.3). Two tabs or
--                  devices write the same row. Pruned at the freeze and at
--                  45 days (the hub's sweep, T007).
--   hours_entries  what the worker decided, per (member, local day, target):
--                  approved minutes or rejected. The natural key is the PK;
--                  writes are ON CONFLICT upserts. A day's total above 1440
--                  minutes is refused by the store (T004), not here.
--   hours_periods  one row per (member, period): the freeze, the return and
--                  the biz owner's approval. There is no watermark.
--
-- All three in the 0098 RLS shape. The runtime grants come from the default
-- privileges of spool-hub-roles/runtime-grants.sql, like every table since 017.
--
-- Also:
--   hours.read, hours.approve  granted to biz_owner only (owner Q5 = A; a biz
--                  owner grants them to other roles through the role editor).
--                  The rows MUST equal internal/rbac Defaults + Permissions
--                  (store TestRBACSeedMatchesDefaults).
--   member_activity.kind gains 'hours_returned' (the 0148 pattern). The
--                  90-day auth sweep (SweepMemberActivity) prunes only
--                  sign_in / sign_out / session_expiry, so the return stays.
--   humans_rail_order_check gains a 12-entry branch with 'hours' (the 0133
--                  pattern); every stored 6..11-entry order stays valid.
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014). The running
-- image reads none of this, so the file applies before the image that does.
-- DEPLOY ORDER: wf 20 applies this before the hub that reads it rolls.

CREATE TABLE hours_minutes (
    tenant_id text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    member_id text        NOT NULL,
    minute    timestamptz NOT NULL CHECK (minute = date_trunc('minute', minute, 'UTC')),
    target    text        NOT NULL CHECK (target ~ '^(t|ch|dm):.{1,200}$' OR target = 'ws'),
    src       text        NOT NULL CHECK (src IN ('post', 'tab')),
    tz        text        NOT NULL CHECK (length(tz) BETWEEN 1 AND 64),
    PRIMARY KEY (tenant_id, member_id, minute)
);
CREATE INDEX hours_minutes_minute ON hours_minutes (minute);

CREATE TABLE hours_entries (
    tenant_id         text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    member_id         text        NOT NULL,
    day               date        NOT NULL,
    target            text        NOT NULL CHECK (target ~ '^(t|ch|dm|cal):.{1,200}$' OR target = 'ws'),
    minutes           integer     NOT NULL CHECK (minutes BETWEEN 0 AND 1440),
    suggested_minutes integer     NOT NULL DEFAULT 0 CHECK (suggested_minutes BETWEEN 0 AND 1440),
    state             text        NOT NULL CHECK (state IN ('approved', 'rejected')),
    note              text        NULL CHECK (length(note) <= 500),
    updated_at        timestamptz NOT NULL DEFAULT now(),
    updated_by        text        NOT NULL,
    PRIMARY KEY (tenant_id, member_id, day, target)
);
CREATE INDEX hours_entries_day ON hours_entries (tenant_id, day);

CREATE TABLE hours_periods (
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    member_id    text        NOT NULL,
    period_start date        NOT NULL,
    period_end   date        NOT NULL,
    state        text        NOT NULL CHECK (state IN ('frozen', 'returned', 'approved')),
    minutes      integer     NOT NULL DEFAULT 0 CHECK (minutes >= 0),
    note         text        NULL CHECK (length(note) <= 500),
    decided_by   text        NOT NULL,
    decided_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, member_id, period_start),
    CHECK (period_end >= period_start),
    CHECK (state <> 'returned' OR coalesce(length(btrim(note)), 0) > 0)
);
CREATE INDEX hours_periods_period ON hours_periods (tenant_id, period_start);

-- RLS in the 0014/0021 shape, with the empty-setting guard (NULLIF, CLE-3416).
ALTER TABLE hours_minutes ENABLE ROW LEVEL SECURITY;
ALTER TABLE hours_minutes FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON hours_minutes
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON hours_minutes
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE hours_entries ENABLE ROW LEVEL SECURITY;
ALTER TABLE hours_entries FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON hours_entries
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON hours_entries
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE hours_periods ENABLE ROW LEVEL SECURITY;
ALTER TABLE hours_periods FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON hours_periods
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON hours_periods
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

INSERT INTO rbac_permissions (permission_id, description) VALUES
    ('hours.read',    'see every member''s approved hours and period states; download them'),
    ('hours.approve', 'approve or return a member''s frozen hours period');

INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES
    ('biz_owner', 'hours.read'), ('biz_owner', 'hours.approve');

ALTER TABLE member_activity DROP CONSTRAINT member_activity_kind_check;
ALTER TABLE member_activity ADD CONSTRAINT member_activity_kind_check CHECK (kind IN (
    'role_changed', 'removed', 'invited', 'invite_accepted',
    'sign_in', 'sign_out', 'session_expiry', 'password_reset', 'hours_returned'));

ALTER TABLE humans DROP CONSTRAINT humans_rail_order_check;

ALTER TABLE humans
    ADD CONSTRAINT humans_rail_order_check
    CHECK (rail_order IS NULL
        OR (cardinality(rail_order) = 6
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events']::text[])
        OR (cardinality(rail_order) = 7
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events','archive']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive']::text[])
        OR (cardinality(rail_order) = 9
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents']::text[])
        OR (cardinality(rail_order) = 10
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes']::text[])
        OR (cardinality(rail_order) = 11
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar']::text[])
        OR (cardinality(rail_order) = 12
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar','hours']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar','hours']::text[]));

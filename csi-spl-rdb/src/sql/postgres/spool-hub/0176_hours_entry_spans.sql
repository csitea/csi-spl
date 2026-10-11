-- 0176_hours_entry_spans.sql - start and end times of hours entries, and the
-- member guard (spec 107 v2.3 section 3.4; spec 118 v1.1 sections 5.2, 5.3).
-- Forward-only, additive. Owner HUM-10, t1 cee5a73e, msg 23d782e1 (Q1 A,
-- Q2 A, Q3 A).
--
-- 1. hours_entry_spans: the times of an entry, one row per interval, written
--    in the same transaction as the entry (store PutHoursEntries): a stopped
--    timer's interval, an approved suggestion's blocks; the v2 plan and clock
--    when they are built. An entry without spans stays valid (Q2 A): its
--    minutes are "unplaced" to spec 118's overlap read. Spans are a raw
--    signal (spec 107 1.7): only /v1/me/hours* serves them.
--      FK (tenant_id, member_id, day, target) -> hours_entries, cascade: a
--      deleted entry takes its spans with it.
--      EXCLUDE (tenant_id =, member_id =, tstzrange &&): two spans of one
--      member in one workspace never overlap, across targets too (spec 118
--      REQ-1: a minute counts once inside a workspace; the hub answers 409
--      overlap_in_workspace). btree_gist gives text its gist equality; it is
--      a trusted contrib extension, like 0143's btree_gin.
--    RLS in the 0014/0021 shape with the NULLIF guard (rls_failclosed_test).
-- 2. member_scope, a RESTRICTIVE policy (USING and WITH CHECK) on
--    hours_entries, hours_entry_spans and hours_minutes. The setting
--    app.member_id is transaction-local (store.inMember), like app.tenant_id.
--    Unset or '' means no member scope: the policy is TRUE, so the team
--    view, the export and the sweep read every member as before. Set, a row
--    passes only when its member_id is that member: a per-member statement
--    that dropped its member_id predicate still reads and writes 0 foreign
--    rows. Restrictive, so it only narrows tenant_scope / operator_scope.
--    The unset test is spelled CASE ... END IS NOT NULL, as 0169's
--    channel_scope, so the planner prices it at 99.5% of the rows and no
--    estimate moves for an unscoped session.
--
-- Live-data safety: one new empty table; CREATE POLICY is catalog-only but
-- holds ACCESS EXCLUSIVE on its table until COMMIT, hence lock_timeout. No
-- deploy order for the policies: no running hub sets app.member_id, so they
-- are TRUE for it. The running image reads no span, so the file applies
-- before the image that does (wf 20). Runtime grants: the default privileges
-- of spool-hub-roles/runtime-grants.sql. Runs under the operator RLS scope
-- (spool migrate, rdb 0014). No personal data, no secret.

SET LOCAL lock_timeout = '5s';

CREATE EXTENSION IF NOT EXISTS btree_gist;

CREATE TABLE hours_entry_spans (
    tenant_id text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    member_id text        NOT NULL,
    day       date        NOT NULL,
    target    text        NOT NULL,
    start_at  timestamptz NOT NULL CHECK (start_at = date_trunc('minute', start_at, 'UTC')),
    end_at    timestamptz NOT NULL CHECK (end_at = date_trunc('minute', end_at, 'UTC')),
    src       text        NOT NULL CHECK (src IN ('activity', 'timer', 'plan', 'clock', 'manual')),
    PRIMARY KEY (tenant_id, member_id, start_at),
    CHECK (end_at > start_at AND end_at - start_at <= interval '1440 minutes'),
    FOREIGN KEY (tenant_id, member_id, day, target)
        REFERENCES hours_entries (tenant_id, member_id, day, target) ON DELETE CASCADE,
    CONSTRAINT hours_entry_spans_no_overlap EXCLUDE USING gist (
        tenant_id WITH =, member_id WITH =, tstzrange(start_at, end_at) WITH &&)
);
-- The entry's spans (the FK's cascade and the per-entry replace).
CREATE INDEX hours_entry_spans_entry ON hours_entry_spans (tenant_id, member_id, day, target);

ALTER TABLE hours_entry_spans ENABLE ROW LEVEL SECURITY;
ALTER TABLE hours_entry_spans FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON hours_entry_spans
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON hours_entry_spans
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

DO $$
DECLARE
    t        text;
    unscoped text := $u$CASE WHEN NULLIF(current_setting('app.member_id', true), '') IS NULL THEN 1 END IS NOT NULL$u$;
BEGIN
    FOREACH t IN ARRAY ARRAY['hours_entries', 'hours_entry_spans', 'hours_minutes'] LOOP
        EXECUTE format($p$CREATE POLICY member_scope ON %1$I AS RESTRICTIVE
            USING (%2$s
                   OR member_id = current_setting('app.member_id', true))
            WITH CHECK (%2$s
                   OR member_id = current_setting('app.member_id', true))$p$, t, unscoped);
    END LOOP;
END
$$;

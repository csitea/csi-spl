-- 0289_use_minutes.sql - hours of use per person, per workspace, per day
-- (SPL-5709, spec 143 usage-hours.md; owner HUM-10, t1 2798773d, msgs
-- 1f0b86e4 and 944839c2: "Measure the amount of time every user spends
-- using each workspace"). Forward-only, additive.
--
--   workspace_use_minutes  the minutes one person used one workspace on one
--                          UTC day. The WUI sends a heartbeat each minute
--                          while a workspace tab is visible and the person
--                          active; the hub adds 1 only when the minute
--                          (hub clock, truncated) is past last_minute, so
--                          two tabs of one workspace count that minute once.
--   hub_use_minutes        the same per person and day across every
--                          workspace: one minute counts once however many
--                          workspaces are open in it. No tenant_id: it is
--                          the estate's. The hub reads it for the operator
--                          workspace's admins (the hub total) and, per
--                          member, for a workspace's owner and admins.
--
-- RLS: workspace_use_minutes in the 0091 shape (tenant scope + operator
-- scope, the NULLIF guard). hub_use_minutes carries the operator policy only
-- (the 0230 shape): a tenant scope and no scope read and write no row.
-- No change_stamp trigger: a heartbeat a minute must not move the channel
-- stamps. Retention: the hub's sweep deletes rows older than 400 days.
-- Live-data safety: two new tables, no row seeded.
-- DEPLOY ORDER: apply BEFORE the hub that writes it (wf 20 does).

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS workspace_use_minutes (
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    human_id    text        NOT NULL CHECK (length(human_id) BETWEEN 1 AND 64),
    day         date        NOT NULL,
    minutes     integer     NOT NULL CHECK (minutes BETWEEN 0 AND 1440),
    last_minute timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, human_id, day)
);
-- the hub total and the sweep read by day
CREATE INDEX IF NOT EXISTS workspace_use_minutes_day ON workspace_use_minutes (day);

CREATE TABLE IF NOT EXISTS hub_use_minutes (
    human_id    text        NOT NULL CHECK (length(human_id) BETWEEN 1 AND 64),
    day         date        NOT NULL,
    minutes     integer     NOT NULL CHECK (minutes BETWEEN 0 AND 1440),
    last_minute timestamptz NOT NULL,
    PRIMARY KEY (human_id, day)
);
CREATE INDEX IF NOT EXISTS hub_use_minutes_day ON hub_use_minutes (day);

ALTER TABLE workspace_use_minutes ENABLE ROW LEVEL SECURITY;
ALTER TABLE workspace_use_minutes FORCE ROW LEVEL SECURITY;
ALTER TABLE hub_use_minutes ENABLE ROW LEVEL SECURITY;
ALTER TABLE hub_use_minutes FORCE ROW LEVEL SECURITY;
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = current_schema()
                   AND tablename = 'workspace_use_minutes' AND policyname = 'tenant_scope') THEN
        CREATE POLICY tenant_scope ON workspace_use_minutes
            USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
            WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = current_schema()
                   AND tablename = 'workspace_use_minutes' AND policyname = 'operator_scope') THEN
        CREATE POLICY operator_scope ON workspace_use_minutes
            USING (current_setting('app.rls_scope', true) = 'operator')
            WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_policies WHERE schemaname = current_schema()
                   AND tablename = 'hub_use_minutes' AND policyname = 'operator_scope') THEN
        CREATE POLICY operator_scope ON hub_use_minutes
            USING (current_setting('app.rls_scope', true) = 'operator')
            WITH CHECK (current_setting('app.rls_scope', true) = 'operator');
    END IF;
END
$$;

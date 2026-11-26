-- 0331_scheduled_tasks.sql - scheduled tasks and activities (spec 187 v0.7
-- section 8.1, build row S1). Forward-only, idempotent (a second apply changes
-- nothing).
--
-- Owner HUM-10 (t1 91992830, 2026-11-20): tasks a workspace (or the instance)
-- runs on a schedule or an event over its channels, topics, messages and
-- issues; their runs are posted in a fifth default channel (D13, msg
-- 5fa95db3: "each workspace should have the scheduled-runs named channel").
--
--   scheduled_tasks      one row per task: its scope (object, channels,
--                        query), its trigger (kind + spec, zone), its action
--                        (kind + spec), its state and next due time. A
--                        workspace task has a tenant_id; an instance task
--                        (D4, D10) has none and runs in every workspace or
--                        a listed set (instance_tenants). The claim of the
--                        due tasks is ONE transaction (store/
--                        scheduled_task_postgres.go ClaimDueTasks), so two
--                        hub instances never run the same due time.
--   scheduled_task_runs  one row per run, keyed by UUIDv5(task_id, cause),
--                        so a second claim of the same cause inserts nothing.
--                        An instance task writes one row in each workspace
--                        it ran in, level 'instance' (D16).
--   hub_settings         the instance settings of spec 187 5.1: no tenant
--                        column, read only by the instance routes and the
--                        runner (the operator scope).
--   #scheduled-runs      the fifth default channel: seeded for every new
--                        workspace by spool_seed_default_channels and
--                        inserted for every existing one below, as 0173 did
--                        for #public.
--
-- RLS: scheduled_task_runs in the 0021 fail-closed NULLIF shape. On
-- scheduled_tasks the same tenant policy never matches a NULL tenant_id, so
-- an instance row is invisible in every tenant scope and readable only in
-- the operator scope. hub_settings has only the operator policy. No
-- change_stamp trigger: no view reads these tables (store change_stamp_test).
-- Runtime grants: the default privileges of spool-hub-roles/runtime-grants.sql.
-- Live-data safety: three new, empty tables; one function replaced in place
-- with the same signature; one channels row per existing tenant (ON
-- CONFLICT DO NOTHING: a workspace that already made a channel of that id
-- keeps it as it is).
-- DEPLOY ORDER: apply before a hub that writes them (spec 187 row S3); an
-- older hub names none, and lists the new channel as an ordinary one.

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS scheduled_tasks (
    tenant_id        text        REFERENCES tenants (tenant_id) ON DELETE CASCADE, -- NULL = instance task
    task_id          uuid        NOT NULL PRIMARY KEY,
    level            text        NOT NULL CHECK (level IN ('workspace', 'instance')),
    name             text        NOT NULL CHECK (name <> '' AND length(name) <= 120),
    owner_id         text        NOT NULL CHECK (owner_id <> '' AND length(owner_id) <= 64),
    template         text        NOT NULL DEFAULT '' CHECK (template IN ('', 'channel_digest', 'stale_issues', 'idle_topics', 'weekly_status')),
    scope_object     text        NOT NULL CHECK (scope_object IN ('channel', 'topic', 'message', 'issue')),
    scope_where      text[]      NOT NULL DEFAULT '{}' CHECK (cardinality(scope_where) <= 50), -- {} = all channels
    scope_query      text        NOT NULL DEFAULT '' CHECK (length(scope_query) <= 1024),
    max_objects      integer     NOT NULL DEFAULT 100 CHECK (max_objects BETWEEN 1 AND 500),
    trigger_kind     text        NOT NULL CHECK (trigger_kind IN ('once', 'every_n_minutes', 'daily', 'weekly', 'monthly', 'cron', 'event')),
    trigger_spec     jsonb       NOT NULL,                       -- cron: {"cron": "<5 fields>"}, at most 64 characters, checked in Go (4.2.1)
    tz               text        NOT NULL DEFAULT 'UTC' CHECK (tz <> '' AND length(tz) <= 64),
    action_kind      text        NOT NULL CHECK (action_kind IN ('move', 'archive', 'label', 'set_priority', 'notify', 'agent')),
    action_spec      jsonb       NOT NULL,
    state            text        NOT NULL DEFAULT 'on' CHECK (state IN ('on', 'paused', 'deleted')),
    paused_reason    text        NOT NULL DEFAULT '' CHECK (paused_reason IN ('', 'by_person', 'done', 'owner_left', 'failing', 'cap')),
    next_due_at      timestamptz,
    fail_streak      integer     NOT NULL DEFAULT 0,
    instance_tenants text[]      NOT NULL DEFAULT '{}',          -- instance task: {} = every workspace
    created_by       text        NOT NULL,
    created_at       timestamptz NOT NULL,
    updated_at       timestamptz NOT NULL,
    deleted_at       timestamptz,
    CHECK ((level = 'instance') = (tenant_id IS NULL))
);
CREATE INDEX IF NOT EXISTS scheduled_tasks_tenant ON scheduled_tasks (tenant_id) WHERE state <> 'deleted';
CREATE INDEX IF NOT EXISTS scheduled_tasks_due ON scheduled_tasks (next_due_at) WHERE state = 'on';
CREATE INDEX IF NOT EXISTS scheduled_tasks_event ON scheduled_tasks (tenant_id, scope_object) WHERE state = 'on' AND trigger_kind = 'event';

CREATE TABLE IF NOT EXISTS scheduled_task_runs (
    tenant_id     text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    run_id        uuid        NOT NULL,                          -- UUIDv5(task_id, cause)
    task_id       uuid        NOT NULL,
    level         text        NOT NULL DEFAULT 'workspace' CHECK (level IN ('workspace', 'instance')), -- D16: which caps it counts against
    cause         text        NOT NULL CHECK (cause <> '' AND length(cause) <= 128),
    chain         uuid[]      NOT NULL DEFAULT '{}' CHECK (cardinality(chain) <= 3), -- D15: the tasks that led here, oldest first
    started_at    timestamptz NOT NULL,
    ended_at      timestamptz,
    outcome       text        NOT NULL DEFAULT 'running' CHECK (outcome IN ('running', 'ok', 'partial', 'failed', 'skipped')),
    matched       integer     NOT NULL DEFAULT 0,
    acted         integer     NOT NULL DEFAULT 0,
    failures      jsonb       NOT NULL DEFAULT '[]',
    error         text        NOT NULL DEFAULT '' CHECK (length(error) <= 500),
    tokens        bigint      NOT NULL DEFAULT 0,
    agent_id      text        NOT NULL DEFAULT '' CHECK (length(agent_id) <= 64), -- D11: who ran an agent run
    result_msg_id uuid,
    PRIMARY KEY (tenant_id, run_id)
);
CREATE INDEX IF NOT EXISTS scheduled_task_runs_task ON scheduled_task_runs (tenant_id, task_id, started_at DESC);

CREATE TABLE IF NOT EXISTS hub_settings (
    key    text        NOT NULL PRIMARY KEY CHECK (key ~ '^[a-z][a-z0-9_.]{0,63}$'),
    value  jsonb       NOT NULL,
    set_by text        NOT NULL,
    set_at timestamptz NOT NULL
);

ALTER TABLE scheduled_tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE scheduled_tasks FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON scheduled_tasks;
CREATE POLICY tenant_scope ON scheduled_tasks
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON scheduled_tasks;
CREATE POLICY operator_scope ON scheduled_tasks
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE scheduled_task_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE scheduled_task_runs FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON scheduled_task_runs;
CREATE POLICY tenant_scope ON scheduled_task_runs
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON scheduled_task_runs;
CREATE POLICY operator_scope ON scheduled_task_runs
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE hub_settings ENABLE ROW LEVEL SECURITY;
ALTER TABLE hub_settings FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS operator_scope ON hub_settings;
CREATE POLICY operator_scope ON hub_settings
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- 0173's body plus 'scheduled-runs' (store.ChannelScheduledRuns).
CREATE OR REPLACE FUNCTION spool_seed_default_channels() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO channels (tenant_id, channel_id, name, created_by)
    SELECT NEW.tenant_id, d.channel_id, d.channel_id, 'hub'
    FROM (VALUES ('lobby'), ('alerts'), ('feedback'), ('public'), ('scheduled-runs')) AS d (channel_id)
    ON CONFLICT (tenant_id, channel_id) DO NOTHING;
    RETURN NEW;
END $$;

-- Every existing workspace, stamped with its #lobby created_at so the idle
-- defaults still tie (as 0173).
INSERT INTO channels (tenant_id, channel_id, name, created_by, created_at)
SELECT t.tenant_id, 'scheduled-runs', 'scheduled-runs', 'hub',
       COALESCE((SELECT c.created_at FROM channels c
                 WHERE c.tenant_id = t.tenant_id AND c.channel_id = 'lobby'), now())
FROM tenants t
ON CONFLICT (tenant_id, channel_id) DO NOTHING;

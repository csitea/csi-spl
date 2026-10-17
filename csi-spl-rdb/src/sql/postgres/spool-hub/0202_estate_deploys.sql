-- 0202_estate_deploys.sql - one row per hub, WUI or infra deploy to dev or
-- prd (spec 143 section 2.3.1, task T001, SPL-2347). Forward-only.
--
-- Owner HUM-10, t1 af25a1f3, poll 3 (msg a8bfcdd0): the deploy step reports
-- each deploy, plus a hub check that catches a missed one. source says which
-- of the two wrote a row:
--   ci         the deploy workflow's report (POST /v1/operator/deploys)
--   reconcile  the hub's reconcile check, which found a served version that
--              no ci row named (deployed_by 'hub-reconcile')
--
-- Estate-wide, like release_notes: no tenant_id. Every scope may READ (the
-- Releases tab shows the deploy stamps to every member); only the operator
-- scope writes (the hub's operator route and its reconcile check). No
-- personal data: ids, versions, shas and a workflow actor name.
--
-- Live-data safety: one new empty table. The runtime grants come from the
-- default privileges of spool-hub-roles/runtime-grants.sql. No running hub
-- reads it yet (spec 143 T020, T025, T027 do, later).

CREATE TABLE estate_deploys (
    deploy_id       text        PRIMARY KEY CHECK (deploy_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    env             text        NOT NULL CHECK (env IN ('dev', 'prd')),
    component       text        NOT NULL CHECK (component IN ('hub', 'wui', 'inf')),
    version         text        NOT NULL CHECK (version ~ '^v[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(-c[0-9]+)?$'),
    commit_sha      text        NOT NULL CHECK (commit_sha ~ '^[0-9a-f]{40}$'),
    deployed_at     timestamptz NOT NULL DEFAULT now(),
    status          text        NOT NULL CHECK (status IN ('success', 'failed')),
    source          text        NOT NULL DEFAULT 'ci' CHECK (source IN ('ci', 'reconcile')),
    workflow_run_id text        NOT NULL DEFAULT '' CHECK (length(workflow_run_id) <= 64),
    deployed_by     text        NOT NULL DEFAULT '' CHECK (length(deployed_by) <= 128)
);

-- The Releases tab reads one env's deploys per UTC day, newest first; the
-- reconcile check reads the newest row per (env, component).
CREATE INDEX estate_deploys_env_day ON estate_deploys (env, ((deployed_at AT TIME ZONE 'UTC')::date), deployed_at DESC);
CREATE INDEX estate_deploys_env_component ON estate_deploys (env, component, deployed_at DESC);
CREATE INDEX estate_deploys_sha ON estate_deploys (commit_sha);

ALTER TABLE estate_deploys ENABLE ROW LEVEL SECURITY;
ALTER TABLE estate_deploys FORCE ROW LEVEL SECURITY;

CREATE POLICY estate_deploys_read ON estate_deploys
    FOR SELECT TO PUBLIC USING (true);

CREATE POLICY operator_scope ON estate_deploys
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

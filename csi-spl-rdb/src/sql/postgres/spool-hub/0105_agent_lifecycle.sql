-- 0105_agent_lifecycle.sql - the agent context lifecycle: the per-workspace
-- config table and the dedicated event log for its empirics (spec 063
-- sections 11 and 12, brief ctx-063/01). Forward-only.
--
-- Owner, t1 64576223: "have those in a db config table in the tenant config
-- section for the admin to be able to config and experiment empirically.
-- Also some logging for the empirics on that would be needed", and "Lets
-- enable our internal gathering into dedicated for this purpose only logging
-- table. Note logging must not decrease performance more than 3%".
--
--   agent_lifecycle_config  one row per tenant. NULL = "the default", and
--                           the default lives in ONE place, the Go table
--                           store.LifecycleKeys, so a new key needs no
--                           backfill and "reset to default" writes NULL (as
--                           tenants.topic_archive_policy, rdb 0093). Each
--                           CHECK is that table's allowed range; a store test
--                           pins the two together.
--   agent_lifecycle_events  the restart, compact and hand-over empirics and
--                           NOTHING else. Append-only, one single-row INSERT,
--                           no trigger, one index (spec 063 12.1); the hub's
--                           retention sweep deletes rows older than 90 days.
--                           writer_box is the box of the authenticated hello
--                           (as in 0096), 'hub' for a config_change.
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply BEFORE the hub that reads these tables.

CREATE TABLE agent_lifecycle_config (
    tenant_id                  text        PRIMARY KEY REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    lane_restart_ctx_k         integer     NULL CHECK (lane_restart_ctx_k BETWEEN 100 AND 950),
    lane_restarts_before_split integer     NULL CHECK (lane_restarts_before_split BETWEEN 1 AND 5),
    seat_restart_ctx_k         integer     NULL CHECK (seat_restart_ctx_k BETWEEN 100 AND 950),
    seat_max_age_min           integer     NULL CHECK (seat_max_age_min BETWEEN 15 AND 240),
    seat_compact_after_fails   integer     NULL CHECK (seat_compact_after_fails BETWEEN 0 AND 5),
    seat_compact_min_ctx_k     integer     NULL CHECK (seat_compact_min_ctx_k BETWEEN 100 AND 950),
    size_check_every_min       integer     NULL CHECK (size_check_every_min BETWEEN 5 AND 60),
    notes_tail_lines           integer     NULL CHECK (notes_tail_lines BETWEEN 0 AND 200),
    seat_fail_action           text        NULL CHECK (seat_fail_action IN ('compact', 'respawn')),
    lane_restart_wall_min      integer     NULL CHECK (lane_restart_wall_min = 0 OR lane_restart_wall_min BETWEEN 10 AND 240),
    lane_checkpoint_min        integer     NULL CHECK (lane_checkpoint_min = 0 OR lane_checkpoint_min BETWEEN 10 AND 240),
    updated_by                 text        NOT NULL DEFAULT '' CHECK (length(updated_by) <= 64),
    updated_at                 timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE agent_lifecycle_events (
    tenant_id     text             NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    at            timestamptz      NOT NULL,
    fleet         text             NOT NULL DEFAULT '' CHECK (length(fleet) <= 32),
    agent_id      text             NOT NULL DEFAULT '' CHECK (length(agent_id) <= 64),
    agent_box     text             NOT NULL DEFAULT '' CHECK (length(agent_box) <= 32),
    writer_box    text             NOT NULL,
    role          text             NOT NULL DEFAULT '' CHECK (role IN ('', 'lane', 'orch', 'master', 'failover')),
    event         text             NOT NULL CHECK (event IN ('restart', 'rotate', 'rotate_fail', 'compact', 'handoff',
                                       'settled', 'session_end', 'checkpoint', 'split', 'config_change')),
    reason        text             NOT NULL DEFAULT '' CHECK (reason IN ('', 'size', 'clock', 'fail-compact', 'done', 'checkpoint', 'manual')),
    rid           text             NOT NULL DEFAULT '' CHECK (length(rid) <= 64),
    ctx_before_k  integer          NULL CHECK (ctx_before_k >= 0),
    ctx_after_k   integer          NULL CHECK (ctx_after_k >= 0),
    age_s         integer          NULL CHECK (age_s >= 0),
    turns         integer          NULL CHECK (turns >= 0),
    tokens_read_m double precision NULL CHECK (tokens_read_m >= 0),
    handoff_lines integer          NULL CHECK (handoff_lines >= 0),
    handoff_bytes integer          NULL CHECK (handoff_bytes >= 0),
    notes_lines   integer          NULL CHECK (notes_lines >= 0),
    refetch       jsonb            NULL,
    config        jsonb            NULL,
    outcome       text             NOT NULL DEFAULT '' CHECK (outcome IN ('', 'ok', 'fail')),
    detail        text             NOT NULL DEFAULT '' CHECK (length(detail) <= 200)
);
-- The one index: a tenant's events newest first (the admin view, the
-- aggregates' window) and the 90-day prune.
CREATE INDEX agent_lifecycle_events_at ON agent_lifecycle_events (tenant_id, at DESC);

-- RLS in the 0021 fail-closed NULLIF shape (the 0096 fleet_lanes pair).
ALTER TABLE agent_lifecycle_config ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_lifecycle_config FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON agent_lifecycle_config
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON agent_lifecycle_config
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE agent_lifecycle_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_lifecycle_events FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON agent_lifecycle_events
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON agent_lifecycle_events
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

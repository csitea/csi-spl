-- 0297_topic_pauses.sql - pause the agents of a discussion (spec 179 v0.3.0
-- section 5.1, build row B1, SPL-5980). Forward-only, idempotent (a second
-- apply changes nothing).
--
-- Owner HUM-10 (prd, msgs 8f7feda6 and defccc7d): "Pause all agents on this
-- discussion. No need to stand by" / "We need the feature to pause agents".
--
--   topic_pauses        one row per paused topic: (tenant_id, task_id), who
--                       paused it, when and why. No row = not paused.
--   topic_pause_issues  one row per issue the pause put on hold: the status
--                       it had, so Resume restores it (spec 179 4.2).
--
-- Their own tables, as topic_priorities (rdb 0214): topic_heads is a trigger
-- projection of messages (rdb 0144), and a message row is a signed envelope.
-- An unpaused topic costs no row; every read is one primary key probe
-- (store/topic_pause_postgres.go).
--
-- Resume guards on membership plus status, never on updated_at: an issue
-- still onhold with a row here goes back, one moved out of onhold by hand
-- stays as it is (spec 179 4.2 step 1).
--
-- The change_stamp trigger (rdb 0103) on topic_pauses: a pause or resume
-- moves the tenant's stamp, so a stamped repeat read of a topic list
-- (hub/view_stamp.go) never answers 304 with the old badge
-- (store/change_stamp_test.go). topic_pause_issues needs none: the issues
-- it holds are written in the same transaction, and issues has its own.
--
-- Live-data safety: two new, empty tables; no existing table is touched.
-- Runtime grants: the default privileges of spool-hub-roles/runtime-grants.sql.
-- DEPLOY ORDER: any time before the hub that reads it (spec 179 row B2).

SET LOCAL lock_timeout = '5s';

CREATE TABLE IF NOT EXISTS topic_pauses (
    tenant_id text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    task_id   uuid        NOT NULL,
    paused_by text        NOT NULL CHECK (paused_by <> '' AND length(paused_by) <= 64),
    paused_at timestamptz NOT NULL,
    reason    text        NOT NULL DEFAULT '' CHECK (length(reason) <= 500),
    PRIMARY KEY (tenant_id, task_id)
);

CREATE TABLE IF NOT EXISTS topic_pause_issues (
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    number      integer     NOT NULL,
    task_id     uuid        NOT NULL,
    prev_status text        NOT NULL CHECK (length(prev_status) <= 16),
    paused_at   timestamptz NOT NULL,
    paused_by   text        NOT NULL DEFAULT '' CHECK (length(paused_by) <= 64),
    PRIMARY KEY (tenant_id, number),
    FOREIGN KEY (tenant_id, number) REFERENCES issues (tenant_id, number) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS topic_pause_issues_task ON topic_pause_issues (tenant_id, task_id);

-- RLS in the 0021 fail-closed NULLIF shape, as topic_priorities (rdb 0214):
-- a tenant reads and writes only its own rows; the operator scope sees
-- everything.
ALTER TABLE topic_pauses ENABLE ROW LEVEL SECURITY;
ALTER TABLE topic_pauses FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON topic_pauses;
CREATE POLICY tenant_scope ON topic_pauses
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON topic_pauses;
CREATE POLICY operator_scope ON topic_pauses
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE topic_pause_issues ENABLE ROW LEVEL SECURITY;
ALTER TABLE topic_pause_issues FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON topic_pause_issues;
CREATE POLICY tenant_scope ON topic_pause_issues
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON topic_pause_issues;
CREATE POLICY operator_scope ON topic_pause_issues
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

DROP TRIGGER IF EXISTS change_stamp ON topic_pauses;
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON topic_pauses
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();

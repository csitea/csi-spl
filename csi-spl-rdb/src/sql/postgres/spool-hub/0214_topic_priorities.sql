-- 0214_topic_priorities.sql - a priority 1..5 per discussion (spec 150
-- v1.0 section 3.3, build row B1, panel D2 and D7, SPL-3052). Forward-only,
-- idempotent (a second apply changes nothing).
--
-- Owner HUM-10 (prd t1 0344254d, msgs 465b73d7 and 2a1c2d12): a radio
-- chooser 1..5 per discussion, and the orchestrator serves the discussions
-- closer to 1 first.
--
--   topic_priorities   one row per topic someone set: (tenant_id, task_id),
--                      the priority, who set it and when
--
-- No row = priority 5, the issues' default (rdb 0054, 0055): there is no
-- "clear", setting 5 is the default, so every change is an upsert. Its own
-- table, not a topic_heads column (only the head trigger writes those, spec
-- 099 4.1) and not a messages column (a topic's priority is not one
-- message's). A list reads it for the task ids of its page only, on the
-- primary key (store/topic_priority_postgres.go).
--
-- The change_stamp trigger (rdb 0103): a set moves the tenant's stamp, so a
-- stamped repeat read of a topic list (hub/view_stamp.go) never answers 304
-- with the old order (spec 150 panel F1; store/change_stamp_test.go).
--
-- Live-data safety: one new, empty table; no existing table is touched.
-- Runtime grants: the default privileges of spool-hub-roles/runtime-grants.sql.
-- DEPLOY ORDER: any time before the hub that reads it (row B3).

CREATE TABLE IF NOT EXISTS topic_priorities (
    tenant_id text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    task_id   uuid        NOT NULL,
    priority  smallint    NOT NULL CHECK (priority BETWEEN 1 AND 5),
    set_by    text        NOT NULL,
    set_at    timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, task_id)
);

-- RLS in the 0021 fail-closed NULLIF shape, as topic_heads (rdb 0144, spec
-- 099 3.4): a tenant reads and writes only its own rows; the operator scope
-- sees everything.
ALTER TABLE topic_priorities ENABLE ROW LEVEL SECURITY;
ALTER TABLE topic_priorities FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON topic_priorities;
CREATE POLICY tenant_scope ON topic_priorities
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON topic_priorities;
CREATE POLICY operator_scope ON topic_priorities
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

DROP TRIGGER IF EXISTS change_stamp ON topic_priorities;
CREATE CONSTRAINT TRIGGER change_stamp AFTER INSERT OR UPDATE OR DELETE ON topic_priorities
    DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION tenant_change_bump();

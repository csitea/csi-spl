-- 0147_box_beats.sql - the box beat of spec 102 section 10.2 (task T017).
-- Forward-only, idempotent (a second apply changes nothing).
--
-- Every box's watchdog writes one row per tick (30 s) over its authenticated
-- hello (`spool box-beat put`); the hub's reply is the beat's ACK. A box whose
-- own beat has not been acked for box_down_min (rdb 0145, default 2) is
-- FENCED: it starts nothing and TERMs its lanes (the watchdog's
-- spl_wd_fence). Not the fleet lease table: 093 6.4 showed a lease row would
-- re-route an agent's channel posts.
--
--   box_beats   append-only. box is the writing box key (from the
--               authenticated hello, never the frame), beat_at the hub's
--               clock (a box's own clock is never trusted), pid the
--               watchdog loop's pid. The hub's retention sweep deletes rows
--               older than store.BoxBeatsRetention (2 days): 3 instances x
--               2880 ticks a day is ~8.6k rows per box per day.
--
-- No personal data: box ids, times and pids. Each CHECK is
-- store/box_beat.go's CheckBoxBeat.
--
-- The runtime grants come from the default privileges of
-- spool-hub-roles/runtime-grants.sql, like every table since 017.
-- DEPLOY ORDER: apply BEFORE the hub that writes this table (wf 20 does).

CREATE TABLE IF NOT EXISTS box_beats (
    id         bigserial   PRIMARY KEY,
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    box        text        NOT NULL CHECK (box ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    beat_at    timestamptz NOT NULL,
    pid        integer     NOT NULL CHECK (pid BETWEEN 1 AND 2147483647)
);
-- The read: one workspace's box (or every box), newest first.
CREATE INDEX IF NOT EXISTS box_beats_tenant_box_at ON box_beats (tenant_id, box, beat_at);
-- The retention prune: every workspace at once.
CREATE INDEX IF NOT EXISTS box_beats_at ON box_beats (beat_at);

-- RLS in the 0106 shape, with the empty-setting guard (NULLIF).
ALTER TABLE box_beats ENABLE ROW LEVEL SECURITY;
ALTER TABLE box_beats FORCE ROW LEVEL SECURITY;
DROP POLICY IF EXISTS tenant_scope ON box_beats;
CREATE POLICY tenant_scope ON box_beats
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
DROP POLICY IF EXISTS operator_scope ON box_beats;
CREATE POLICY operator_scope ON box_beats
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

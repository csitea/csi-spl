-- 0137_flow_events_place_key.sql - each Flow event carries the place it
-- belongs to and the time its read coverage is measured at (API perf plan
-- v0.2, row ap-01a, csi-spl-doc/doc/md/refactor-round-api-perf-plan-2026-10-06.md).
-- Forward-only.
--
-- Why: the Flow badge (store/flow_postgres.go flowCountsSQL) joins every
-- event the member ever got to its message and probes read_marks for each,
-- nearly all of them already read (prd 24 h: 865.5 s, n=11 229 x 77.1 ms).
-- With the place and the time on the event row, a later change (ap-01b) can
-- seek past each place's mark and read only the uncovered tail. This file
-- changes no read: 0 on its own.
--
--   place_key  the sidebar key of the message, flowCountsSQL's expression:
--              'ch:<channel>', else 'dm:<from_id>@<from_box>', else
--              'dm:<from_id>' (an empty from_box)
--   cov_at     the message's received_at: the time a place / topic mark is
--              compared with (flowCoveredSQL). NOT flow_events.at, which is
--              the 'f:seen' clock and is never rewritten here.
--
-- Kept current: a move or a topic merge rewrites a message's channel, task
-- and received_at (message_move_postgres.go, topic_merge_postgres.go) and
-- nothing else updates flow_events, so an AFTER UPDATE trigger on messages
-- refreshes both columns of the line's events. Backfilled by msg_id, never by
-- `at` (on prd some events' `at` differs from their message's received_at).
--
-- Written by the hub's insert (flowInsertCTE). A hub older than that leaves
-- them NULL; the BEFORE INSERT trigger below fills those from the message, so
-- the rows written between this file and the new hub are not stale.
--
-- DEPLOY ORDER: apply BEFORE the hub that writes place_key / cov_at, on dev
-- AND prd. The old hub ignores the columns.

ALTER TABLE flow_events ADD COLUMN place_key text, ADD COLUMN cov_at timestamptz;

CREATE FUNCTION spool_flow_place_key(channel text, from_id text, from_box text) RETURNS text
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
        SELECT CASE WHEN channel IS NOT NULL THEN 'ch:' || channel
            WHEN coalesce(from_box, '') <> '' THEN 'dm:' || from_id || '@' || from_box
            ELSE 'dm:' || from_id END
    $$;

-- A line moved or merged: its events follow it. Only the line's own events
-- (flow_events_msg), and only the rows whose keys change. Never `at`.
CREATE FUNCTION flow_events_place_refresh() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    UPDATE flow_events fe
       SET place_key = spool_flow_place_key(NEW.channel, NEW.from_id, NEW.from_box),
           cov_at = NEW.received_at
     WHERE fe.tenant_id = NEW.tenant_id AND fe.msg_id = NEW.msg_id
       AND (fe.place_key, fe.cov_at) IS DISTINCT FROM
           (spool_flow_place_key(NEW.channel, NEW.from_id, NEW.from_box), NEW.received_at);
    RETURN NULL;
END
$$;

CREATE TRIGGER messages_flow_place
    AFTER UPDATE OF channel, task_id, from_id, from_box, received_at ON messages
    FOR EACH ROW
    WHEN (OLD.channel IS DISTINCT FROM NEW.channel OR OLD.from_id IS DISTINCT FROM NEW.from_id
       OR OLD.from_box IS DISTINCT FROM NEW.from_box OR OLD.received_at IS DISTINCT FROM NEW.received_at)
    EXECUTE FUNCTION flow_events_place_refresh();

-- An insert that did not write the keys (a hub older than flowInsertCTE's
-- place_key): fill them from the message, stored earlier in the same
-- statement. A hub that writes them pays one NULL test.
CREATE FUNCTION flow_events_place_fill() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
    SELECT spool_flow_place_key(m.channel, m.from_id, m.from_box), m.received_at
      INTO NEW.place_key, NEW.cov_at
      FROM messages m WHERE m.tenant_id = NEW.tenant_id AND m.msg_id = NEW.msg_id;
    RETURN NEW;
END
$$;

CREATE TRIGGER flow_events_place_fill
    BEFORE INSERT ON flow_events
    FOR EACH ROW WHEN (NEW.place_key IS NULL OR NEW.cov_at IS NULL)
    EXECUTE FUNCTION flow_events_place_fill();

-- Backfill every event from its message (operator scope: this file runs in
-- one transaction). prd: ~5 000 rows.
SELECT set_config('app.rls_scope', 'operator', true);
UPDATE flow_events fe
   SET place_key = spool_flow_place_key(m.channel, m.from_id, m.from_box),
       cov_at = m.received_at
  FROM messages m
 WHERE m.tenant_id = fe.tenant_id AND m.msg_id = fe.msg_id;

-- ap-01b's seek: one member's events of one place after its mark.
CREATE INDEX flow_events_place ON flow_events (tenant_id, member_id, place_key, cov_at, msg_id);

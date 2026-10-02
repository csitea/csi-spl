-- 0104_flow_events.sql - the per-member Flow (spec 062, contract
-- specs/062-flow-per-user-counts/contracts/flow-v1.md). Forward-only.
--
-- The owner (t1 25826b7b, 11:21Z): a Facebook-like number on top of the Flow
-- pane, and "that flow page to show ONLY the flow events relevant to that
-- user". Relevance is decided once, when a line is stored (in the same
-- statement as INSERT messages, store/flow_postgres.go), so the badge and the
-- page are one indexed read each instead of a walk over every thread the
-- member ever posted in (spec 062 section 4.1).
--
--   flow_watches  the threads a member watches: they posted in it, were
--                 @-mentioned in it, or were its `to` (spec 2.2)
--   flow_events   one row per (member, message) with ONE reason, the
--                 strongest of mention > poke > dm > reply (spec 2.1).
--                 Deleted with its message (FK cascade), so the retention
--                 sweep and a message delete need no code of their own.
--
-- Read state stays in read_marks: 'f:seen' (the pane was opened) and
-- 'f:<msg_id>' (an entry opened from the Flow); the CHECK below admits them.
--
-- DEPLOY ORDER: apply BEFORE the hub that writes these tables.

CREATE TABLE flow_watches (
    tenant_id  text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    task_id    uuid        NOT NULL,
    member_id  text        NOT NULL,
    since      timestamptz NOT NULL,
    PRIMARY KEY (tenant_id, task_id, member_id)
);

CREATE TABLE flow_events (
    tenant_id   text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    member_id   text        NOT NULL,
    msg_id      uuid        NOT NULL,
    task_id     uuid        NOT NULL,
    kind        text        NOT NULL CHECK (kind IN ('mention', 'poke', 'dm', 'reply')),
    at          timestamptz NOT NULL,  -- the message's received_at
    expires_at  timestamptz NOT NULL,  -- the message's expires_at
    PRIMARY KEY (tenant_id, member_id, msg_id),
    FOREIGN KEY (tenant_id, msg_id) REFERENCES messages (tenant_id, msg_id) ON DELETE CASCADE
);
-- The badge and the page: one member's events, newest first.
CREATE INDEX flow_events_member_at ON flow_events (tenant_id, member_id, at DESC, msg_id DESC);
-- The FK cascade, and the live fan-out's "who got an event for this line".
CREATE INDEX flow_events_msg ON flow_events (tenant_id, msg_id);

-- RLS in the 0014/0021 shape, with the empty-setting guard (NULLIF, CLE-3416).
ALTER TABLE flow_watches ENABLE ROW LEVEL SECURITY;
ALTER TABLE flow_watches FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON flow_watches
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON flow_watches
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

ALTER TABLE flow_events ENABLE ROW LEVEL SECURITY;
ALTER TABLE flow_events FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON flow_events
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON flow_events
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

-- 'f:seen' and 'f:<msg_id>' next to the WUI cursor keys.
ALTER TABLE read_marks DROP CONSTRAINT read_marks_mark_key_check;
ALTER TABLE read_marks ADD CONSTRAINT read_marks_mark_key_check
    CHECK (mark_key ~ '^(ch|t|dm|f):.{1,200}$');

-- Backfill the watches from the lines still in retention (spec 5.2): each
-- human author (or the human who typed the line at a terminal) and each
-- human `to` watches the thread. No events are backfilled, so the first
-- badge is 0, not a flood. Operator scope: this file runs in one transaction.
SELECT set_config('app.rls_scope', 'operator', true);
INSERT INTO flow_watches (tenant_id, task_id, member_id, since)
SELECT tenant_id, task_id, member_id, min(received_at)
FROM (
    SELECT tenant_id, task_id, coalesce(typed_by, from_id) AS member_id, received_at
    FROM messages WHERE expires_at > now()
    UNION ALL
    SELECT tenant_id, task_id, to_id, received_at
    FROM messages WHERE expires_at > now()
) w
WHERE member_id ~ '^(HUM|GST)-[0-9]+$'
GROUP BY tenant_id, task_id, member_id
ON CONFLICT DO NOTHING;

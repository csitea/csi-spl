-- 0097_fleet_asks.sql — a durable record per ask to the orchestrator
-- (CLE-77929, owner bug t1 #spool-hub-bugs 2f7996aa). Forward-only.
--
-- Owner, 2026-10-02 (t1 692aefe8, 01:58Z): "there needs to be some kind a
-- state mechanism both in the db and on the file system, that you must fire
-- and forget and then the orchestrator (or the next orchestrator if the
-- previous one just died) would know to check and get and continue".
--
-- An escalation used to be one spool file in the orchestrator's inbox plus a
-- poke line in its pane; nothing marked it handled, so it sank under the
-- notes that followed it (the orchestrator's inbox: 954 messages, 0
-- archived), and a successor on another machine never saw it at all (the
-- file is on the old holder's disk). Now a blocker / task / escalation sent
-- to the orchestrator also writes ONE row here, keyed by the spool msg_id
-- that carried it:
--
--   open -> acked (in progress, by <ID>@<box>) -> done | declined (reason)
--
-- The acting orchestrator (the fleet lease's orch holder, any machine) lists
-- the open rows on start and on every lease tick, and the tick re-raises a
-- row nobody acked (raised_n / raised_at) and, later, tells the owner once
-- (escalated_at). The local journal (<spool root>/asks/) mirrors every row,
-- so a sender without the hub still records its ask and syncs it later.
--
-- The shape is a Kafka-like log on what the estate already has (owner, t1
-- 12d34d3a: "resembles the main principle of how Kafka works ... use
-- whatever we have: a database, a file system, distributed nodes, the
-- agents"): role is the topic (the recipient role: orch today, dispatch
-- next), a row is a record keyed by its msg_id (an idempotent producer), and
-- the per-record state is the consumer's commit - acked when taken, done or
-- declined when handled. Delivery is at least once: an uncommitted record is
-- re-delivered (re-raised) until a consumer commits it, and a successor
-- replays every uncommitted record of its role. Retention: a week after
-- commit.
--
-- writer_box is the box that last wrote the row, from the authenticated hello
-- (an audit column the client cannot choose). A write prunes the fleet's
-- closed rows a week after their last write.
CREATE TABLE fleet_asks (
    tenant_id    text        NOT NULL REFERENCES tenants (tenant_id) ON DELETE CASCADE,
    fleet        text        NOT NULL CHECK (fleet ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    ask_id       text        NOT NULL CHECK (ask_id ~ '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'),
    role         text        NOT NULL DEFAULT 'orch' CHECK (role ~ '^[a-z0-9][a-z0-9-]{0,31}$'),
    kind         text        NOT NULL CHECK (kind IN ('blocker', 'task', 'escalation')),
    from_agent   text        NOT NULL CHECK (from_agent ~ '^[A-Z]{2,4}-[0-9]{1,9}(@[a-z0-9][a-z0-9-]{0,31})?$'),
    topic        text        NOT NULL DEFAULT '' CHECK (topic ~ '^([A-Za-z0-9_-]{1,64})?$'),
    summary      text        NOT NULL DEFAULT '' CHECK (length(summary) <= 500),
    state        text        NOT NULL CHECK (state IN ('open', 'acked', 'done', 'declined')),
    deadline_at  timestamptz,
    acked_by     text        NOT NULL DEFAULT '' CHECK (acked_by ~ '^([A-Z]{2,4}-[0-9]{1,9}(@[a-z0-9][a-z0-9-]{0,31})?)?$'),
    closed_by    text        NOT NULL DEFAULT '' CHECK (closed_by ~ '^([A-Z]{2,4}-[0-9]{1,9}(@[a-z0-9][a-z0-9-]{0,31})?)?$'),
    reason       text        NOT NULL DEFAULT '' CHECK (length(reason) <= 500),
    raised_n     integer     NOT NULL DEFAULT 0 CHECK (raised_n >= 0),
    raised_at    timestamptz,
    escalated_at timestamptz,
    writer_box   text        NOT NULL,
    created_at   timestamptz NOT NULL DEFAULT now(),
    updated_at   timestamptz NOT NULL DEFAULT now(),
    PRIMARY KEY (tenant_id, fleet, ask_id)
);

-- The orchestrator's question is "what is still open": a partial index keeps
-- that read off the week of closed history.
CREATE INDEX fleet_asks_open ON fleet_asks (tenant_id, fleet, role, created_at)
    WHERE state IN ('open', 'acked');

-- RLS in the 0021 fail-closed NULLIF shape: a tenant reads and writes only
-- its own fleet's rows; the operator scope (spool migrate) sees everything.
ALTER TABLE fleet_asks ENABLE ROW LEVEL SECURITY;
ALTER TABLE fleet_asks FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON fleet_asks
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON fleet_asks
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

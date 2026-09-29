-- 0083_messages_task_received_covering.sql — make the per-topic task index
-- fully covering, so the topic-walk AGGREGATE (not just its probes) runs
-- index-only (perf round e908f41b, lane B). Forward-only.
--
-- The topic list (viewTopicsSQL, ~40% of prd database time) reads each listed
-- topic's messages twice through messages_task_received: the recursive
-- latest/first LIMIT-1 probes, and the per-topic aggregate (count, the kinds
-- array, the parties = from_id@from_box + to_id@to_box). The aggregate
-- HEAP-fetched kind/from_id/from_box/to_id/to_box for every message of every
-- listed topic. TopicAccess (25k calls/day) reads the same rows for
-- channel/from_id/to_id.
--
-- Carrying those columns as INCLUDE payload on messages_task_received's
-- (tenant_id, task_id, received_at, msg_id) key makes the aggregate, the
-- door/parties probes AND TopicAccess all Index Only Scans. It is a strict
-- superset of 0082's messages_topic_access (same task rows, more payload,
-- plus the received_at/msg_id ordering the aggregate needs), so 0082 is
-- dropped here rather than left as dead weight.
--
-- Measured pg 16.14, owner under the tenant RLS scope, t1 300k messages:
--   topic-walk page (51)   19.5 ms median (bare) -> 14.7 ms (9.1 ms min), aggregate Heap Fetches 0
--   TopicAccess            Index Scan 155 buffers -> Index Only Scan (Heap Fetches 0)
--   insert cost            20k rows 723 ms -> 756 ms (+4.5%); the index is ~43% larger
-- The walk is ~40% of prd db time and inserts ~9%, so the read win dominates.
-- msg (jsonb) and env (bytea) stay out of the payload on purpose: the first
-- message's body and the thread page's envelope are single-row heap reads that
-- do not justify the size.
--
-- DROP + CREATE INDEX (not CONCURRENTLY) inside the migrate transaction takes a
-- brief ACCESS EXCLUSIVE lock while it rebuilds; messages is small enough that
-- it is seconds. No RLS clause: an index inherits the table's policies.

DROP INDEX IF EXISTS messages_topic_access;

DROP INDEX IF EXISTS messages_task_received;
CREATE INDEX messages_task_received
    ON messages (tenant_id, task_id, received_at, msg_id)
    INCLUDE (expires_at, channel, from_id, from_box, to_id, to_box, kind, parent_task_id);

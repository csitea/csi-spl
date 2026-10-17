-- 0206_channel_humans_only.sql — the humans-only mark of a channel (SPL-2423).
-- Forward-only.
--
-- Owner HUM-10, 2026-10-17: "once the users have removed all of the agents
-- from the properties of a channel, no new agents should be added by the
-- system" (poll answer A: humans only, no agent is a member, none reads or
-- posts in it).
--
-- humans_only_at NULL = an ordinary channel. Set = since when a person's
-- remove left the channel with no agent; the hub clears it when a person
-- invites an agent again. The desk reconcile (do_spl_dispatch_subscribe)
-- adds no OD seat to a marked channel, the hub delivers none of its posts to
-- an agent, and the unanswered sweep leaves it out.
--
-- A column without a default: the running image ignores it, so this file
-- rolls before the image that reads it. The table's RLS policies cover it.

-- SET CONSTRAINTS first: `spool migrate --dry-run` applies every pending file
-- in ONE transaction, and an earlier file's deferred trigger events on
-- channels would make the ALTER fail (SQLSTATE 55006). Firing them now is
-- what COMMIT does in a per-file run.
SET CONSTRAINTS ALL IMMEDIATE;
ALTER TABLE channels ADD COLUMN IF NOT EXISTS humans_only_at timestamptz;

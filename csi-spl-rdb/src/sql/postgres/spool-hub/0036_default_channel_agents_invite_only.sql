-- 0036_default_channel_agents_invite_only.sql — a member picks the agents of
-- #lobby, #tasks and #alerts (owner decision 2026-09-25, channels-v1 §7.4).
-- Forward-only.
--
-- Before this, every announced agent read the default channels: #lobby by
-- rule, #tasks and #alerts through the origin 'announce' rows a box wrote
-- when it listed them in SPOOL_CHANNELS. From now on an announce never
-- writes a row for a default channel, and a default channel's agents are
-- its origin 'invite' rows only. The announce rows already stored would
-- otherwise keep those agents in, so they go. Invite and removed rows stay.
-- People are untouched: every member of the tenant still reads them.

DELETE FROM channel_subscriptions
WHERE origin = 'announce'
  AND channel_id IN ('lobby', 'tasks', 'alerts');

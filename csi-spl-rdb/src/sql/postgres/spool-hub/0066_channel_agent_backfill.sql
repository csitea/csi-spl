-- 0066_channel_agent_backfill.sql — an agent added to a channel is back-filled
-- with the channel's recent traffic (SPL-987, specs/038 FR-020..FR-026).
-- Forward-only.
--
-- Owner, 2026-09-27: "whenever I invite bots in the channel they should
-- subscribe for messages from there". The invite itself worked; the posts
-- made BEFORE it never reached the agent, so it did not know what it was
-- invited for.
--
-- backfilled_at on an invited seat is the one-shot marker: NULL = the hub
-- still owes this agent the channel's recent posts; set = done (or there was
-- nothing to send). The hub runs a pending back-fill on the invite call and
-- on the box's next hello, so a seat written by the operator path
-- (do_spl_channel_agent_add_op, a plain INSERT) is back-filled too. A
-- re-invite keeps the stamp, so it never re-delivers.
--
-- Every seat that exists when this runs is stamped as done: those agents
-- were seated under the old rule and have been receiving live posts since.

ALTER TABLE channel_subscriptions ADD COLUMN IF NOT EXISTS backfilled_at timestamptz;

UPDATE channel_subscriptions SET backfilled_at = subscribed_at WHERE backfilled_at IS NULL;

CREATE INDEX IF NOT EXISTS channel_subscriptions_backfill_pending
    ON channel_subscriptions (tenant_id, box_id)
    WHERE backfilled_at IS NULL AND origin = 'invite';

-- 0033_channel_subscription_removed.sql — a member can take an agent
-- back out of a channel (channels-v1 §7.4). Forward-only.
--
-- origin 'removed' is an exclusion. The next announce deletes only
-- origin 'announce' and inserts with ON CONFLICT DO NOTHING, so a removed
-- row is not put back.

ALTER TABLE channel_subscriptions
    DROP CONSTRAINT IF EXISTS channel_subscriptions_origin_chk;

ALTER TABLE channel_subscriptions
    ADD CONSTRAINT channel_subscriptions_origin_chk
    CHECK (origin IN ('announce', 'invite', 'removed'));

-- 0032_channel_subscription_origin.sql — a person can invite an agent into
-- a channel (channels-v1 §7.4). Forward-only.
--
-- An announce replaces the box's previous set. An invite must survive that
-- replace, or the agent leaves the channel the next time its box says hello.
-- origin 'announce' is what hello wrote and what the next hello may delete.
-- origin 'invite' is what a member added from the channel Properties dialog
-- and is left in place.

ALTER TABLE channel_subscriptions
    ADD COLUMN IF NOT EXISTS origin text NOT NULL DEFAULT 'announce';

ALTER TABLE channel_subscriptions
    DROP CONSTRAINT IF EXISTS channel_subscriptions_origin_chk;

ALTER TABLE channel_subscriptions
    ADD CONSTRAINT channel_subscriptions_origin_chk
    CHECK (origin IN ('announce', 'invite'));

-- 0073_membership_channel_order.sql — a person's own order of the Channels list
-- (SPL-1034, specs/045 §3.8). Forward-only.
--
-- Owner, 2026-09-28 (topic 49a2588c): "one should be able to drag and drop the
-- channels to define their order".
--
-- Per person AND per tenant, because a channel id only means something inside
-- its tenant: the membership row already has exactly that key (and the tenant
-- RLS, rdb 0014), so the order lives there.
--
-- channel_order  the channel ids in the person's order, first on top.
--                NULL = never set: the WUI shows today's order.
--                A channel the list does not name renders after these (so a
--                new channel appears at the end); an id that no longer exists
--                is ignored when rendering and kept here.
--
-- One nullable column: the running image ignores it, so this file rolls before
-- the image that writes it.

ALTER TABLE tenant_memberships
    ADD COLUMN IF NOT EXISTS channel_order text[] NULL;

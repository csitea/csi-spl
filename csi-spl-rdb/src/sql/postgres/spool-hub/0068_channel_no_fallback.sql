-- 0068_channel_no_fallback.sql — a channel can opt out of the fallback
-- responder (SPL-997, specs/038 FR-039). Forward-only.
--
-- CLE-001, 2026-09-27, after the fallback went live: proof and test runs
-- post as a human into channels that have no agent on purpose (#live-proof),
-- and every such post now pokes the tenant's responder. A channel with
-- no_fallback = true keeps the old behaviour: an unheard post there reaches
-- no agent. People's channels keep the default (false). Set per channel with
-- the csi-spl-orc action do_spl_channel_fallback; no test id is hard-coded.
--
-- A column with a default: the running image ignores it, so this file rolls
-- before the image that reads it.

ALTER TABLE channels ADD COLUMN IF NOT EXISTS no_fallback boolean NOT NULL DEFAULT false;

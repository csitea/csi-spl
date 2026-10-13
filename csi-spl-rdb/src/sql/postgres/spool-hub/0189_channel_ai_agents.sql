-- 0189_channel_ai_agents.sql — the per-channel "AI agents" switch (SPL-1684).
-- Forward-only.
--
-- Owner decision (a workspace poll, both admins voted B): the AI agents are
-- turned on with a button per channel, off by default in that workspace.
-- When a channel's switch is off, the hub does not fan its posts out to the
-- member agents' boxes, does not back-fill or hand them to the fallback
-- responder, and the unanswered sweep leaves them out. A DM to an agent and
-- an explicit @agent dispatch still reach it (the direct to_box leg).
--
-- ai_agents NULL = follow the workspace default, the tenants.settings key
-- channel_ai_agents (spec 098, no migration; absent = true, so a workspace
-- without the setting behaves byte for byte as before). true / false = the
-- channel's own switch, set from its Properties -> Settings.
-- ai_agents_at is when the switch last changed: the unanswered sweep's delta
-- read re-reads that channel's topics after it (perf round 5 P5-01).
--
-- Columns without a default: the running image ignores them, so this file
-- rolls before the image that reads them. The table's RLS policies cover
-- the new columns.

ALTER TABLE channels ADD COLUMN IF NOT EXISTS ai_agents boolean;
ALTER TABLE channels ADD COLUMN IF NOT EXISTS ai_agents_at timestamptz;

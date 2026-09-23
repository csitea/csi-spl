-- 0028_channel_humans.sql — a channel is something humans are IN, not
-- something every member of the tenant can read. Forward-only.
--
-- Until this file, channel_subscriptions (0002) held AGENTS only
-- (agent_id, box_id): it answers "which boxes must this post be delivered
-- to", never "who may read it". Humans had no channel membership at all, so
-- every signed-in member of a tenant could read every channel of that tenant,
-- and GET /v1/view/threads/{task_id} handed any thread to anyone who knew its
-- uuid. This table is the missing half.
--
-- SCOPE (owner's call, 2026-09-23): the three DEFAULT channels — lobby, tasks,
-- alerts — stay tenant-wide public and get NO rows here; the fan-out already
-- treats lobby as "the whole announced roster", and gating it would fragment
-- the one channel every tester needs. Only CREATED channels are membership-
-- gated, and a non-member cannot learn one exists: it is absent from
-- GET /v1/view/channels and its threads read 404.
--
-- BACKFILL (owner's call, same): membership is derived from evidence, never
-- from "everyone who happens to be in the tenant" — that would carry the leak
-- forward under a new name. A created channel admits exactly
--   * its creator (channels.created_by, when that is a HUM-*), and
--   * every human who has posted in it or been addressed in it.
-- Anyone else is out on the first deploy and has to be added. That is the
-- point: it is what turns the reported defect off rather than renaming it.
--
-- RLS: the 0021 fail-closed form (NULLIF — a pooled connection reads the GUC
-- as '' after any transaction-local set_config, never NULL), matching
-- channel_subscriptions. Membership is exactly as readable as its channel.

CREATE TABLE channel_humans (
    tenant_id  text        NOT NULL,
    channel_id text        NOT NULL,
    -- tenant_memberships.human_id. No FK: humans/tenant_memberships are
    -- hub-wide and not tenant-scoped (0006), and a membership row that
    -- outlives a removed member is harmless — the read door asks
    -- MemberRole on every request, so a removed member is already out.
    human_id   text        NOT NULL,
    joined_at  timestamptz NOT NULL DEFAULT now(),
    -- who put them there: a HUM-* with channels.manage, or 'hub' for a
    -- backfilled / creator row.
    added_by   text        NOT NULL DEFAULT 'hub',
    PRIMARY KEY (tenant_id, channel_id, human_id),
    FOREIGN KEY (tenant_id, channel_id) REFERENCES channels (tenant_id, channel_id) ON DELETE CASCADE
);

-- "which channels is this human in" — the sidebar and the thread-list filter
-- ask it on every browser request. The primary key answers the other
-- direction (who is in this channel) already.
CREATE INDEX channel_humans_human ON channel_humans (tenant_id, human_id);

-- The creator of every created channel.
INSERT INTO channel_humans (tenant_id, channel_id, human_id, added_by)
SELECT c.tenant_id, c.channel_id, c.created_by, 'hub'
FROM channels c
WHERE c.created_by ~ '^HUM-'
  AND c.channel_id NOT IN ('lobby', 'tasks', 'alerts')
ON CONFLICT DO NOTHING;

-- Everyone who has posted in a created channel, or been addressed in one.
-- Retention is NOT applied: a member of a quiet channel must not be dropped
-- because their last post aged out of the window.
INSERT INTO channel_humans (tenant_id, channel_id, human_id, added_by)
SELECT DISTINCT m.tenant_id, m.channel, h.id, 'hub'
FROM messages m
JOIN channels c ON c.tenant_id = m.tenant_id AND c.channel_id = m.channel
CROSS JOIN LATERAL (VALUES (m.from_id), (m.to_id)) AS h (id)
WHERE m.channel IS NOT NULL
  AND m.channel NOT IN ('lobby', 'tasks', 'alerts')
  AND h.id ~ '^HUM-'
ON CONFLICT DO NOTHING;

ALTER TABLE channel_humans ENABLE ROW LEVEL SECURITY;
ALTER TABLE channel_humans FORCE ROW LEVEL SECURITY;
CREATE POLICY tenant_scope ON channel_humans
    USING (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''))
    WITH CHECK (tenant_id = NULLIF(current_setting('app.tenant_id', true), ''));
CREATE POLICY operator_scope ON channel_humans
    USING (current_setting('app.rls_scope', true) = 'operator')
    WITH CHECK (current_setting('app.rls_scope', true) = 'operator');

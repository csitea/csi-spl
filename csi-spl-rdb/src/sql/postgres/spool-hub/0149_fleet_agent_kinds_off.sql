-- 0149_fleet_agent_kinds_off.sql - switch an agent kind off for the whole
-- instance, and pause one that ran out of quota. Forward-only, additive.
--
-- Owner HUM-10, t1 41fa1f2d: "we should have a setting to disable certain
-- type of ai agents - for example now the grok is out of tokens ... so it
-- should not be inited", "in the same place in the cloud instance
-- configuration where we configure the load default for the whole instance".
--
--   tenants.fleet_agent_kinds_off    the agent kinds no box starts a new lane
--                                    of (claude, grok, agy, qwen); NULL = none.
--                                    Only the operator workspace's admin sets
--                                    it (PATCH /v1/operator/fleet-load); the
--                                    hub refuses switching every kind off.
--   tenants.fleet_agent_kinds_paused {"<kind>": {"until": <RFC 3339>,
--                                    "reason": "<text>", "box": "<box id>"}}:
--                                    a timed pause a box reports when one of
--                                    its lanes hit the kind's usage limit, so
--                                    every box skips that kind until then.
--
-- The setting is the INSTANCE's, as 0118 / 0134: only the operator
-- workspace's row (tenants.is_operator, rdb 0116) is read. The box's lane mix
-- (csi-spl-orc do_spl_lane_mix) reads it; the hub stores it and enforces
-- nothing. The hub checks each entry; the CHECKs here keep the shapes.
--
-- NULL columns: a catalog-only ADD COLUMN, no rewrite, and the running image
-- ignores them. RLS is unchanged: tenants already ENABLE + FORCE it (0021).
-- No personal data: agent kinds, times and box ids only.
-- DEPLOY ORDER: apply BEFORE the hub that bundles this file (spec 072 A45).

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS fleet_agent_kinds_off text[] NULL
        CONSTRAINT tenants_fleet_agent_kinds_off_check CHECK (
            fleet_agent_kinds_off <@ ARRAY['claude', 'grok', 'agy', 'qwen']::text[]),
    ADD COLUMN IF NOT EXISTS fleet_agent_kinds_paused jsonb NULL
        CONSTRAINT tenants_fleet_agent_kinds_paused_check CHECK (jsonb_typeof(fleet_agent_kinds_paused) = 'object');

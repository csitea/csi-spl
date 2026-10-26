-- 0229_fleet_token_work_tenant.sql — every workspace sees its own token
-- costs (spec 140 section 3.10, SPL-3565; owner HUM-10, t1 f3ed0eed, msgs
-- 1bb1f74b "each of the workspaces should be able to distinguish between the
-- token costs of it's own workspace - all of the roles should be able to
-- check those costs" and 96d69790 "but the admin of the spoool-hub should be
-- able to see the costs of the other workspaces as well"). Forward-only,
-- additive, idempotent.
--
--   fleet_token_burn_events.work_tenant, fleet_token_burn_daily.work_tenant
--       the workspace the lane works for, stamped by the hub when it writes
--       the minute (the lane's fleet_lanes topic, spec 153 3.7, read in the
--       workspace that holds it). NULL = the operator workspace's own work,
--       and every row written before this file. The rows stay operator-scope
--       (0199's RLS, unchanged): a workspace reads its own through the hub's
--       cost route, which filters on this column, never through RLS.
--   costs.read  now every member role's (owner 1bb1f74b): biz_owner and
--       admin held it since 0166. demo_user and channel_guest stay without
--       it (a visitor, not a member), time_accountant too (an add-on role
--       0222 pins to the two hours ids; its holder's member role grants it).
--       Who sees the estate is the hub's: the operator workspace's admin only.
--
-- The rows MUST equal internal/rbac Defaults (store
-- TestRBACSeedMatchesDefaults). ADD COLUMN with no default is catalog-only
-- (no rewrite); the partial indexes hold the attributed rows only.
-- DEPLOY ORDER: wf 20 applies this file before it rolls the hub that writes
-- the column; the running hub names its columns, so it never sees it.

SET LOCAL lock_timeout = '5s';

ALTER TABLE fleet_token_burn_events ADD COLUMN IF NOT EXISTS work_tenant text NULL
    CHECK (work_tenant ~ '^[a-z0-9][a-z0-9-]{0,31}$');
ALTER TABLE fleet_token_burn_daily ADD COLUMN IF NOT EXISTS work_tenant text NULL
    CHECK (work_tenant ~ '^[a-z0-9][a-z0-9-]{0,31}$');

CREATE INDEX IF NOT EXISTS fleet_token_burn_work_tenant
    ON fleet_token_burn_events (work_tenant, minute_bucket) WHERE work_tenant IS NOT NULL;
CREATE INDEX IF NOT EXISTS fleet_token_burn_daily_work_tenant
    ON fleet_token_burn_daily (work_tenant, day_bucket) WHERE work_tenant IS NOT NULL;

INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES
    ('product_owner', 'costs.read'), ('developer', 'costs.read'), ('tester', 'costs.read'),
    ('pure_agent', 'costs.read'), ('biz_customer', 'costs.read'), ('regular_user', 'costs.read')
ON CONFLICT DO NOTHING;

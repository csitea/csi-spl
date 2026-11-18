-- 0294_hours_prices.sql - the hours.prices permission (spec 107 21.5 rule 1,
-- task T078, SPL-5871; owner HUM-10 poll e47404d1 msg a7ec216c: the biz
-- owner sets each person's hourly price, in a tab of Expenses).
-- Forward-only, additive.
--
--   hours.prices  set and read each person's hourly price in the workspace.
--                 No route asks it yet (T071, T072 build the table and the
--                 routes); computed money stays hours.rates (rdb 0222).
--
-- Granted to biz_owner alone and pinned there, as rdb 0222 and 0223 pin
-- hours.rates to time_accountant: a CHECK on rbac_role_permissions (a
-- system or custom role grant) and one on tenant_role_grants (the spec 152
-- role x action override), so neither the operator nor a workspace's role
-- editor can hand it on.
--
-- Live-data safety: one row in rbac_permissions, one in
-- rbac_role_permissions; both CHECKs hold on every existing row, because
-- no row names hours.prices before this file (its FK to rbac_permissions).
-- No member, setting or hours row changes. No personal data, no secret.

SET LOCAL lock_timeout = '5s';

INSERT INTO rbac_permissions (permission_id, description) VALUES
    ('hours.prices', 'set and read each person''s hourly price')
ON CONFLICT DO NOTHING;

INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES
    ('biz_owner', 'hours.prices')
ON CONFLICT DO NOTHING;

ALTER TABLE rbac_role_permissions ADD CONSTRAINT hours_prices_biz_owner_only
    CHECK (permission_id <> 'hours.prices' OR role_id = 'biz_owner');

ALTER TABLE tenant_role_grants ADD CONSTRAINT tenant_role_grants_hours_prices
    CHECK (permission_id <> 'hours.prices' OR role_id = 'biz_owner');

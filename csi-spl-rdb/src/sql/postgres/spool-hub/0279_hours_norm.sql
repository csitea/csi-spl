-- 0279_hours_norm.sql - the hours.norm permission (spec 107 FR-41, SPL-5440;
-- owner HUM-10, t1 59a7062f msgs b46e7fe3 and df038453: the biz_owner and
-- the product_owner set the average hours a human may register per
-- workspace; answers: per day, a soft norm, the workspace admin too).
-- Forward-only, additive.
--
--   hours.norm  set the workspace's average hours per day: the registered
--               tenants.settings key hours.norm_day_minutes (rdb 0136, no
--               column), written by PUT /v1/hours/norm. A soft norm: no
--               entry is refused for it; a member sees their day against it.
--
-- Granted to biz_owner, product_owner and admin. Not a cell of the role x
-- action list (spec 152 3.1): a system grant only.
--
-- Live-data safety: one row in rbac_permissions, three in
-- rbac_role_permissions; no member, no setting and no hours row changes.
-- No personal data, no secret.

SET LOCAL lock_timeout = '5s';

INSERT INTO rbac_permissions (permission_id, description) VALUES
    ('hours.norm', 'set the workspace''s average hours per day')
ON CONFLICT DO NOTHING;

INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES
    ('biz_owner', 'hours.norm'), ('product_owner', 'hours.norm'), ('admin', 'hours.norm')
ON CONFLICT DO NOTHING;

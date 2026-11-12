-- 0276_accountant_roles.sql - the costs.write permission and the two
-- accountant roles (spec 123 section 16, spec 025 section 12; SPL-5359;
-- owner HUM-10, csitea #csi-fina 2026-11-12: "create a new role which is
-- internal-accountant for all of the workspaces", "add also the
-- external-accountant role in each workspace"). Forward-only, additive.
--
--   costs.write          enter and delete the hand-entered cost entries
--                        (cloud, hr; rdb 0245). Those rows are the estate's
--                        (no tenant_id), so the hub lets only a holder in the
--                        OPERATOR workspace write them (hub/cost_entries.go);
--                        in any other workspace it opens nothing yet.
--   internal_accountant  topics.read + costs.read + costs.write: every
--                        browser door asks topics.read (hub humanTenant), so
--                        it works alone or on top of a member role; no
--                        topics write, no member admin, no operator route.
--   external_accountant  costs.read + costs.write, an outside seat: no
--                        topics.read, ended by access_until (rdb 0113), like
--                        time_accountant (rdb 0222). Until a costs-only
--                        browser door exists the hub refuses it at that door.
--
-- biz_owner and admin get costs.write too: a role is granted only by an actor
-- that covers its permissions (025 section 3.4), so without it an admin could
-- not grant either accountant role.
--
-- Live-data safety: seven seed rows in rbac_role_permissions, one in
-- rbac_permissions, two in rbac_roles; no member gets a role here (the
-- orchestrator adds people after the land, on the owner's go). No personal
-- data, no secret.

SET LOCAL lock_timeout = '5s';

INSERT INTO rbac_permissions (permission_id, description) VALUES
    ('costs.write', 'enter and delete the hand-entered cost entries (cloud, hr); the operator workspace''s only today')
ON CONFLICT DO NOTHING;

INSERT INTO rbac_roles (role_id, tenant_owner, description) VALUES
    ('internal_accountant', false, 'enters the hand-entered costs and reads the cost report and topics; no topics write (spec 123 16)'),
    ('external_accountant', false, 'an outside accountant: enters the hand-entered costs and reads the cost report; no topics, ended by access_until (spec 123 16)')
ON CONFLICT DO NOTHING;

INSERT INTO rbac_role_permissions (role_id, permission_id) VALUES
    ('biz_owner', 'costs.write'), ('admin', 'costs.write'),
    ('internal_accountant', 'topics.read'), ('internal_accountant', 'costs.read'), ('internal_accountant', 'costs.write'),
    ('external_accountant', 'costs.read'), ('external_accountant', 'costs.write')
ON CONFLICT DO NOTHING;

-- 0243_pins_box_mode_fleet.sql - a pin a fleet desk box enrolled (spec 158
-- section 4.2 item 4, build row T7, POST /v1/fleet/enrol): "a new workspace
-- works automatically" (owner HUM-10, t1 99ffa592, msg e0510945).
-- Forward-only, additive, idempotent.
--
--   pins.box_mode          += 'fleet': the key a fleet desk box (rdb 0230
--                          fleet_desk_boxes) enrolled with its operator-
--                          workspace box key, into a workspace with
--                          tenants.fleet_seating true. 0170 allowed
--                          'dedicated' and 'shared' only.
--   pins_history.reason    += 'fleet': the history row of that enrolment.
--                          0119 allowed pin, force, revoke, join, wui-revoke
--                          and membership-end only.
--
-- Both CHECKs only widen, so every existing row still passes the re-check
-- the ADD makes (one scan of each table, both small: one row per seated box
-- and per pin change). No new column, no RLS change (pins and pins_history
-- keep their policies), no personal data.
-- DEPLOY ORDER: wf 20 applies this file to dev and prd before it rolls the
-- hub that writes 'fleet'; the running hub never writes it.

SET LOCAL lock_timeout = '5s';

ALTER TABLE pins DROP CONSTRAINT IF EXISTS pins_box_mode_check;
ALTER TABLE pins ADD CONSTRAINT pins_box_mode_check
    CHECK (box_mode IN ('dedicated', 'shared', 'fleet'));

ALTER TABLE pins_history DROP CONSTRAINT IF EXISTS pins_history_reason_check;
ALTER TABLE pins_history ADD CONSTRAINT pins_history_reason_check
    CHECK (reason IN ('pin', 'force', 'revoke', 'join', 'wui-revoke', 'membership-end', 'fleet'));

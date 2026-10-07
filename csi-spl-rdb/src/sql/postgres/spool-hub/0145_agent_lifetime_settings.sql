-- 0145_agent_lifetime_settings.sql - the five agent lifetime settings (spec
-- 102 v1.0 section 11.1, task T011) as new columns of 063's
-- agent_lifecycle_config (rdb 0105). Forward-only, idempotent (a second
-- apply changes nothing).
--
-- NULL = the default, and the default lives in ONE place, the Go table
-- store.LifecycleKeys (rows marked Lifetime), as for every 0105 column. Each
-- CHECK is that table's allowed range; TestLifecycleKeysPinRdbChecks pins
-- the two together.
--
--   restart_max_per_hour  default 3,  1..10   restarts of one id per hour (6.1)
--   rebirth_max           default 7,  1..50   rebirths of one task (6.2)
--   task_restart_max      default 12, 1..100  restarts of one task (6.2)
--   stuck_min             default 10, 2..60   minutes before S9 stuck (8.1)
--   box_down_min          default 2,  1..30   minutes before a box is down (10.2)
--
-- These are fleet-wide: the hub reads them from the OPERATOR workspace's row
-- only (store.ReadLifetimeSettings); the same columns on any other
-- workspace's row are ignored. The 0105 RLS policies and the runtime grants
-- (default privileges, spool-hub-roles/runtime-grants.sql) cover the new
-- columns as they are.
-- DEPLOY ORDER: any order. A hub that reads these columns probes for them
-- and serves the defaults until this file is applied.

ALTER TABLE agent_lifecycle_config
    ADD COLUMN IF NOT EXISTS restart_max_per_hour integer NULL CHECK (restart_max_per_hour BETWEEN 1 AND 10),
    ADD COLUMN IF NOT EXISTS rebirth_max          integer NULL CHECK (rebirth_max BETWEEN 1 AND 50),
    ADD COLUMN IF NOT EXISTS task_restart_max     integer NULL CHECK (task_restart_max BETWEEN 1 AND 100),
    ADD COLUMN IF NOT EXISTS stuck_min            integer NULL CHECK (stuck_min BETWEEN 2 AND 60),
    ADD COLUMN IF NOT EXISTS box_down_min         integer NULL CHECK (box_down_min BETWEEN 1 AND 30);

-- 0154_pins_pubkey_unique.sql - one live pin per box key, across every
-- workspace (specs/108-workspace-owned-boxes T006, spec section 3.2).
-- Forward-only, additive, idempotent.
--
-- Spec 3.2: "The public key is globally unique across all workspaces
-- (exempting box-wui, since the hub pins its own key in every workspace).
-- Uniqueness is enforced by a unique index on live pins(pubkey)". So a box
-- key pinned live in one workspace cannot be pinned live again, in that
-- workspace or another; the hub answers pin_conflict (T007) and never names
-- the other workspace.
--
--   live      revoked_at IS NULL: a revoked pin's key may be pinned again.
--   box-wui   the hub's own browser box, marked by box_id = 'box-wui' (no
--             column of its own), pinned with one key in every workspace:
--             exempt.
--
-- Live duplicates counted before this file, read-only with do_spl_db_query
-- (operator scope, rolled-back transaction), 2026-10-08: dev 0 of 18 live
-- pins (3 box-wui), prd 0 of 45 live pins (13 box-wui). A duplicate would
-- fail the build and roll this migration back, changing nothing.
--
-- Plain CREATE UNIQUE INDEX, not CONCURRENTLY: the runner (internal/store
-- migrate.go) applies each file in its own transaction, where CONCURRENTLY is
-- refused. pins is tens of rows; the SHARE lock lasts milliseconds.
-- RLS is unchanged: pins already ENABLE + FORCE it (0014). No personal data.
-- DEPLOY ORDER: none; the running hub reads nothing new.

CREATE UNIQUE INDEX IF NOT EXISTS pins_pubkey_live_unique
    ON pins (pubkey)
    WHERE revoked_at IS NULL AND box_id <> 'box-wui';

-- 0170_box_join_switch.sql - spec 108 (workspace-owned boxes) behind a
-- per-workspace switch, OFF by default (owner HUM-10, t1 65f75266, msg
-- 9bdc5980: "this whole feature should be switchable on and off, and the
-- default should be off for now"), and the box mode a join records (msg
-- 45f51dbd: restricted workspaces next to shared boxes). Spec 108 section
-- 3.8. Forward-only, additive.
--
--   tenants.box_join_enabled  the switch. false: the hub refuses to mint a
--                             join token and to redeem one (403
--                             box_join_disabled); boxes already seated keep
--                             working. true: joins are open, to dedicated
--                             boxes only. Only an admin of the operator
--                             workspace writes it (PATCH
--                             /v1/operator/workspaces/{id}, or the shell
--                             action do_spl_box_join_switch).
--   pins.box_mode             the mode a box declared, signed by its box key,
--                             when it joined: 'dedicated' (enrolled into one
--                             workspace, do_spl_box_workspace_setup) or
--                             'shared'. NULL on every root-key pin and on every
--                             pin before this file: read as shared.
--
-- DEFAULT false for every workspace, existing ones included. NOT NULL with a
-- constant default is a catalog-only ADD COLUMN (pg 11+), no rewrite, and the
-- running image ignores both columns. RLS is unchanged: tenants and pins
-- already ENABLE + FORCE it, and a column needs no policy of its own. No
-- change_stamp trigger: the flag is read per mint and per redeem. No personal
-- data.
-- DEPLOY ORDER: apply to dev and prd BEFORE the hub that reads it (spec 072
-- A45; wf 20 migrates each env before it rolls).

ALTER TABLE tenants
    ADD COLUMN IF NOT EXISTS box_join_enabled boolean NOT NULL DEFAULT false;

ALTER TABLE pins
    ADD COLUMN IF NOT EXISTS box_mode text NULL
        CONSTRAINT pins_box_mode_check CHECK (box_mode IN ('dedicated', 'shared'));

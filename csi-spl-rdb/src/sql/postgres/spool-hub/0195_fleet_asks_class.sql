-- 0195_fleet_asks_class.sql — a queued spawn request carries its work class,
-- and the queue places by class (SPL-1817). Forward-only.
--
-- Owner HUM-10, t1 3209f8b8: "the refactoring should take the majority of
-- the resources, then bug fixing, and only after that, new feature
-- additions" (msg a25bfdd6), "at least 20% to 30% ... only dedicated to
-- refactoring" (msg 36ee9cec), and the binding one (msg 8cb6cc7d): "20% to
-- 30% refactoring, 20% to 30% bug fixing ... the rest will be new feature
-- implementation. Should I want some kind of bypass lane for a new feature
-- that I need really fast, I will have to do that explicitly. You have to
-- keep track for me".
--
-- class  : ci (a CI-red fix on trunk, the head exception) | refactor | bug |
--          feature; '' only on asks that never were queued. The queue's
--          order (store askPositions): ci, a flagged row, refactor, bug,
--          feature, then enqueued_at. The bands of the live lanes are the
--          placer's (do_spl_spawn_place); the rule's one home is
--          csi-spl-doc/doc/md/fleet-rules-index.md.
-- flag   : '' | urgent (a bug placed over its band: owner-reported prd
--          breakage) | bypass (a feature placed outside the bands, ONLY on
--          the owner's explicit ask: flag_msg is that owner message id).
-- flag_by, flag_at: who set the flag and when (the bypass record the
--          owner's share report lists).
-- A request waiting in the queue at this change has no class: it is a bug.
-- A lane placed before it keeps '' and is 'unknown' in the share.
ALTER TABLE fleet_asks ADD COLUMN class text NOT NULL DEFAULT ''
    CHECK (class IN ('', 'ci', 'refactor', 'bug', 'feature'));
ALTER TABLE fleet_asks ADD COLUMN flag text NOT NULL DEFAULT ''
    CHECK (flag IN ('', 'urgent', 'bypass'));
ALTER TABLE fleet_asks ADD COLUMN flag_msg text NOT NULL DEFAULT ''
    CHECK (flag_msg ~ '^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12})?$');
ALTER TABLE fleet_asks ADD COLUMN flag_by text NOT NULL DEFAULT '';
ALTER TABLE fleet_asks ADD COLUMN flag_at timestamptz;
ALTER TABLE fleet_asks ADD CONSTRAINT fleet_asks_flag_class_check
    CHECK (flag = '' OR (flag = 'urgent' AND class = 'bug') OR (flag = 'bypass' AND class = 'feature' AND flag_msg <> ''));

UPDATE fleet_asks SET class = 'bug' WHERE class = '' AND enqueued_at IS NOT NULL
    AND state IN ('queued', 'acked');

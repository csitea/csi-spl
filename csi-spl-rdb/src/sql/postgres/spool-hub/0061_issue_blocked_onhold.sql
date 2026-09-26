-- 0061_issue_blocked_onhold.sql — two more issue statuses in every tenant
-- (SPL-966, specs/039, CLE-34993). Forward-only.
--
-- Owner, 2026-09-26: "add the 05 - blocked format into all the tenants ...
-- for the issues"; "there should be 06-onhold status also".
--   blocked  05-blocked: waiting on something or someone
--   onhold   06-onhold:  paused on purpose, not blocked
-- Order: 01-eval, 02-todo, 03-wip, 03-diss, 05-blocked, 06-onhold, 07-qas,
-- 09-done. The statuses are global (one CHECK), so every tenant has them.
-- Existing rows are unchanged. The first set's names stay admitted, as in
-- rdb 0055, for an older writer.

ALTER TABLE issues DROP CONSTRAINT issues_status_check;
ALTER TABLE issues ADD CONSTRAINT issues_status_check CHECK (status IN
    ('eval', 'todo', 'wip', 'diss', 'blocked', 'onhold', 'qas', 'done',
     'backlog', 'in_progress', 'in_review', 'canceled'));

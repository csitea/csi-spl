-- 0055_issue_prio_status.sql — "prio" is a plain number 1..5 and the status
-- set is the owner's (specs/039, CLE-34993). Forward-only.
--
-- Owner, 2026-09-26 10:35 (topic d81cbf47): "change the priority control,
-- should be just called prio, prio should be from 1 till 5, just a number".
-- 1 is the highest. Linear's 1 urgent .. 4 low keep their numbers; 0 ("no
-- priority", which sorted last) becomes 5, the lowest, so no issue moves in
-- a priority sort. New rows default to 5.
--
-- Owner, 2026-09-26 10:38 (topic f2c32da2): the status options are 01-eval,
-- 02-todo, 03-wip, 03-diss, 07-qas, 09-done (numbered labels in the WUI; the
-- stored ids are eval, todo, wip, diss, qas, done). Existing rows move:
-- backlog -> eval, todo -> todo, in_progress -> wip, in_review -> qas,
-- done -> done, canceled -> diss. completed_at / canceled_at keep meaning
-- done / diss.
--
-- rdb 0054 (GRK-3508, the same owner request) already widened the priority
-- check to 0..5 and kept 0 for "never picked"; this file moves those 0 rows
-- to 5 and makes 5 the default. The status check still admits the old values
-- for the roll window: the hub that runs while this file is applied writes
-- status backlog for a new issue. The hub that reads them (0.7.7) never
-- writes an old value and reads one as its new equivalent.

UPDATE issues SET priority = 5 WHERE priority = 0;
ALTER TABLE issues ALTER COLUMN priority SET DEFAULT 5;

ALTER TABLE issues DROP CONSTRAINT issues_status_check;
UPDATE issues SET status = CASE status
    WHEN 'backlog' THEN 'eval'
    WHEN 'in_progress' THEN 'wip'
    WHEN 'in_review' THEN 'qas'
    WHEN 'canceled' THEN 'diss'
    ELSE status END
WHERE status IN ('backlog', 'in_progress', 'in_review', 'canceled');
ALTER TABLE issues ADD CONSTRAINT issues_status_check CHECK (status IN
    ('eval', 'todo', 'wip', 'diss', 'qas', 'done',
     'backlog', 'in_progress', 'in_review', 'canceled'));
ALTER TABLE issues ALTER COLUMN status SET DEFAULT 'eval';

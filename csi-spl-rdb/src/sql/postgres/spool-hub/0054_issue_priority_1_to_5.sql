-- 0054_issue_priority_1_to_5.sql — prio is a number 1..5.
-- Forward-only. 0 stays allowed for a row that never picked one.
-- Applied by spool migrate before a hub that accepts priority 5 is served.

ALTER TABLE issues DROP CONSTRAINT IF EXISTS issues_priority_check;
ALTER TABLE issues ADD CONSTRAINT issues_priority_check CHECK (priority BETWEEN 0 AND 5);

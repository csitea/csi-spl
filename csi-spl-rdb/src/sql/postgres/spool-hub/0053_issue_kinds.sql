-- 0053_issue_kinds.sql — the issue tree has three levels (SPL-18, specs/039
-- §8, CLE-34993). Forward-only.
--
-- Owner, 2026-09-26 09:08 (topic 070843ba): "epic and features are the first
-- level / left most panel, issues (could be bugs, tasks, etc.) and those
-- could have subtasks in the third level".
--
-- kind is the level-1 marker, a column (Linear: projects are not labels):
--   epic | feature   level 1, no parent
--   issue            level 2 when its parent is an epic / feature, level 3
--                    (a subtask) when its parent is a level-2 issue
-- The `feature` LABEL stays a free type label (bug, feature, ...): rows that
-- carry it are level-2 issues and are not touched here. rdb 0049 made epics
-- with the `epic` label; they become kind epic. The hub enforces the tree.

ALTER TABLE issues ADD COLUMN kind text NOT NULL DEFAULT 'issue'
    CHECK (kind IN ('epic', 'feature', 'issue'));

UPDATE issues SET kind = 'epic' WHERE 'epic' = ANY (labels);

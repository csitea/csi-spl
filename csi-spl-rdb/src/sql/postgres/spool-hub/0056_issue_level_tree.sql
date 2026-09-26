-- 0056_issue_level_tree.sql — an issue's level is its place in the tree,
-- 1, 2 or 3 and nothing else (SPL-949, specs/039, CLE-34993). Forward-only.
--
-- Owner, 2026-09-26 (topic e5759793): "change the level attribute values in
-- the issues, the levels should be 1, 2, 3 - nothing else".
--
-- rdb 0047 made level the t-shirt estimate 0..5; prd held 0..4 with no link
-- to the tree. From here level is the tree of rdb 0053:
--   1  epic / feature (no parent)
--   2  an issue under a level-1 row
--   3  a subtask: an issue under a level-2 issue
-- An issue with no parent (only rows older than the tree rule) reads 2, as
-- the hub derives it. The hub derives level on every write; it is never
-- taken from input.

UPDATE issues i SET level = CASE
        WHEN i.kind IN ('epic', 'feature') THEN 1
        WHEN i.parent_number IS NULL THEN 2
        WHEN (SELECT p.kind FROM issues p
              WHERE p.tenant_id = i.tenant_id AND p.number = i.parent_number) IN ('epic', 'feature') THEN 2
        ELSE 3
    END;

ALTER TABLE issues DROP CONSTRAINT issues_level_check;
ALTER TABLE issues ALTER COLUMN level SET DEFAULT 2;
ALTER TABLE issues ADD CONSTRAINT issues_level_check CHECK (level IN (1, 2, 3));

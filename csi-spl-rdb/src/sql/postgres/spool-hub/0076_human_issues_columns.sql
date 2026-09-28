-- 0076_human_issues_columns.sql — a person's Issues sheet column widths
-- (SPL-1132, spec 039). Forward-only. humans is hub-wide and outside row
-- level security, like the other layout choices (0070, 0072).
--
-- Owner, prd t1 topic beb4024f: "the columns of the issues grid should be
-- resizable". The widths are remembered per person, on every device.
--
-- NULL = never sized: the WUI keeps the sheet's automatic layout, so nobody's
-- view changes until they drag a column.
-- issues_columns  a JSON object of sheet column -> width in CSS px, e.g.
--                 {"key": 96, "status": 140}. The hub admits only the known
--                 columns and whole widths 24..2000 (auth.IsIssueColumns);
--                 the CHECK pins the shape.
ALTER TABLE humans
    ADD COLUMN IF NOT EXISTS issues_columns jsonb NULL;

ALTER TABLE humans DROP CONSTRAINT IF EXISTS humans_issues_columns_check;
ALTER TABLE humans ADD CONSTRAINT humans_issues_columns_check
    CHECK (issues_columns IS NULL OR jsonb_typeof(issues_columns) = 'object');

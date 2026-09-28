-- 0072_human_issues_view.sql — how a person's Issues page is laid out
-- (SPL-1028, spec 039 FR-012). Forward-only. humans is hub-wide and outside
-- row level security, like the other layout choices (0070).
--
-- Owner, 2026-09-28 (prd t1 topic 89485c7a): "introduce the Linear-style
-- grouping of issues in views, i.e. the default is a list, but there could
-- be a view by status as well". The chosen view is remembered per person.
--
-- NULL = never picked: the WUI shows the list, so nobody's view changes
-- until they choose.
-- issues_view  'list'   : the sheet, one flat list (the default).
--              'status' : the same rows grouped by status, workflow order.
ALTER TABLE humans
    ADD COLUMN IF NOT EXISTS issues_view text NULL;

ALTER TABLE humans DROP CONSTRAINT IF EXISTS humans_issues_view_check;
ALTER TABLE humans ADD CONSTRAINT humans_issues_view_check
    CHECK (issues_view IS NULL OR issues_view IN ('list','status'));

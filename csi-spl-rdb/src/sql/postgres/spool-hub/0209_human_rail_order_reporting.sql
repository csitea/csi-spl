-- 0209_human_rail_order_reporting.sql - the left rail gets one more entry,
-- Reporting (spec 143 1.1; SPL-2351 drew it, SPL-2587 admits it), reorderable
-- like the other twelve (SPL-979, spec 023 3.8). Forward-only. Widens the 0198
-- check (the 0133 pattern); does not rewrite that file. Every stored order
-- stays valid: the six, seven, nine, ten, eleven, the twelve with 'hours'
-- (0151) and the twelve with 'monitoring' (0198). A new order holds the twelve
-- with 'monitoring' plus 'reporting'; the WUI draws an older one with the new
-- tab appended (parseRailOrder).
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014). The running
-- image never writes 'reporting' (auth.IsRailOrder refuses it), so the file
-- applies before the image that does.
-- DEPLOY ORDER: wf 20 applies this before the hub that reads it rolls.
ALTER TABLE humans DROP CONSTRAINT humans_rail_order_check;

ALTER TABLE humans
    ADD CONSTRAINT humans_rail_order_check
    CHECK (rail_order IS NULL
        OR (cardinality(rail_order) = 6
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events']::text[])
        OR (cardinality(rail_order) = 7
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events','archive']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive']::text[])
        OR (cardinality(rail_order) = 9
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents']::text[])
        OR (cardinality(rail_order) = 10
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes']::text[])
        OR (cardinality(rail_order) = 11
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar']::text[])
        OR (cardinality(rail_order) = 12
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar','hours']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar','hours']::text[])
        OR (cardinality(rail_order) = 12
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar','monitoring']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar','monitoring']::text[])
        OR (cardinality(rail_order) = 13
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar','monitoring','reporting']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar','monitoring','reporting']::text[]));

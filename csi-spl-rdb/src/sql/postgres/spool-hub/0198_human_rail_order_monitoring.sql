-- 0198_human_rail_order_monitoring.sql - the left rail gets one more entry,
-- Monitoring (owner HUM-10, t1 dbf2f39b, msg 94283d6b; SPL-1990), reorderable
-- like the other eleven (SPL-979, spec 023 3.8). Forward-only. Widens the 0151
-- check (the 0133 pattern); does not rewrite that file. Every stored order
-- stays valid: the six, seven, nine, ten and eleven, and the twelve with
-- 'hours' 0151 admits. A new order holds the eleven plus 'monitoring'; the WUI
-- draws an older one with the new tab appended (parseRailOrder).
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014). The running
-- image never writes 'monitoring' (auth.IsRailOrder refuses it), so the file
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
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar','monitoring']::text[]));

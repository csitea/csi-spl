-- 0248_human_rail_order_expenses.sql - the left rail gets one more entry,
-- Expenses (spec 143 costs-redesign.md 3.8; SPL-4382; owner HUM-10, t1
-- 4f48f878, msg 4cea9710), reorderable like the other fourteen (SPL-979, spec
-- 023 3.8). Forward-only. Widens the 0224 check (the 0133 pattern); does not
-- rewrite that file. Every stored order stays valid: the six, seven, nine,
-- ten, eleven, the twelve with 'hours' (0151), the twelve with 'monitoring'
-- (0198), the thirteen with 'reporting' (0209) and the fourteen with 'notes'
-- (0224). A new order holds the fourteen plus 'expenses'; the WUI draws an
-- older one with the new tab appended (parseRailOrder).
--
-- Runs under the operator RLS scope (spool migrate, rdb 0014). The running
-- image never writes 'expenses' (auth.IsRailOrder refuses it), so the file
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
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar','monitoring','reporting']::text[])
        OR (cardinality(rail_order) = 14
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar','monitoring','reporting','notes']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar','monitoring','reporting','notes']::text[])
        OR (cardinality(rail_order) = 15
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar','monitoring','reporting','notes','expenses']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar','monitoring','reporting','notes','expenses']::text[]));

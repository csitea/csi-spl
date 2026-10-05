-- 0133_human_rail_order_calendar.sql — the left rail gets one more entry,
-- Calendar (spec 089 T007), reorderable like the other ten (SPL-979, spec 023 3.8).
-- Forward-only. Widens the 0090 check; does not rewrite that file. A rail_order
-- stored before Calendar existed (the six, the seven with archive, the nine
-- with people + agents, or the ten with boxes) stays valid; the WUI draws it
-- with the new tab appended (parseRailOrder). A new order holds all eleven.
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
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes','calendar']::text[]));

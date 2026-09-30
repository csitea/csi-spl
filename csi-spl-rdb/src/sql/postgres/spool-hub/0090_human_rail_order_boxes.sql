-- 0090_human_rail_order_boxes.sql — the left rail gets one more entry, Boxes
-- (CLE-77799), reorderable like the other nine (SPL-979, spec 023 3.8).
-- Forward-only. Widens the 0087 check; does not rewrite that file. A rail_order
-- stored before Boxes existed (the six, the seven with archive, or the nine
-- with people + agents) stays valid; the WUI draws it with the new tab appended
-- (parseRailOrder). A new order holds all ten.
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
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents','boxes']::text[]));

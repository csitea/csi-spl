-- 0087_human_rail_order_people_agents.sql — the left rail gets two more
-- entries, People and Agents (CLE-77794), reorderable like the other seven
-- (SPL-979, spec 023 3.8). Forward-only. Widens the 0064 check; does not
-- rewrite that file. A rail_order stored before these existed (the six, or the
-- seven with archive) stays valid; the WUI draws it with the new tabs appended
-- (parseRailOrder). A new order holds all nine.
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
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive','people','agents']::text[]));

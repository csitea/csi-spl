-- 0064_human_rail_order_archive.sql — the left rail gets a 7th entry,
-- Archive (SPL-983), reorderable like the six (SPL-979, spec 023 3.8).
-- Forward-only. Widens the 0063 check; does not rewrite that file.
-- A rail_order stored before Archive existed (the six, each once) stays
-- valid; the WUI draws it with archive appended. A new order holds all seven.
ALTER TABLE humans DROP CONSTRAINT humans_rail_order_check;

ALTER TABLE humans
    ADD CONSTRAINT humans_rail_order_check
    CHECK (rail_order IS NULL
        OR (cardinality(rail_order) = 6
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events']::text[])
        OR (cardinality(rail_order) = 7
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events','archive']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events','archive']::text[]));

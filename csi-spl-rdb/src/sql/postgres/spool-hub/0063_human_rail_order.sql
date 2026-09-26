-- 0063_human_rail_order.sql — the order of a person's left-rail icons
-- (SPL-979, spec 023 3.8). Forward-only. humans is hub-wide and outside row
-- level security, like submit_key (0062).
-- NULL = never reordered: the WUI draws its default order.
-- Otherwise exactly the six rail ids, each once, in the person's order
-- (both containments + six elements = a permutation).
ALTER TABLE humans
    ADD COLUMN rail_order text[] NULL
        CONSTRAINT humans_rail_order_check
        CHECK (rail_order IS NULL OR (
            cardinality(rail_order) = 6
            AND rail_order <@ ARRAY['dm','channels','issues','topics','flow','events']::text[]
            AND rail_order @> ARRAY['dm','channels','issues','topics','flow','events']::text[]));

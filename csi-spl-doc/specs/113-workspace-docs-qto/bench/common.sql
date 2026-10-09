-- spec 113 tree bench: shared helpers (seed tree, assert).
-- Loaded first in every model's psql session by tree-bench.sh.

CREATE EXTENSION IF NOT EXISTS ltree;
-- sql functions below name tables the load step creates later
SET check_function_bodies = off;

CREATE OR REPLACE FUNCTION bench_assert(ok boolean, what text) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  IF ok IS NOT TRUE THEN
    RAISE EXCEPTION 'ASSERT FAILED: %', what;
  END IF;
END $$;

-- seed: one document, a root (id 0) plus `levels` levels of `fanout`
-- children each. sortkey is the outline number (1.3.2 = {1,3,2}), pre the
-- preorder index (root = 1), sz the subtree size. Every model loads from it.
CREATE OR REPLACE FUNCTION seed_build(fanout int, levels int) RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  l int;
  n bigint;
BEGIN
  DROP TABLE IF EXISTS seed;
  CREATE TABLE seed (
    id bigint PRIMARY KEY, parent_id bigint, ord int NOT NULL,
    depth int NOT NULL, sortkey int[] NOT NULL, pre int, sz int);
  INSERT INTO seed (id, parent_id, ord, depth, sortkey)
  VALUES (0, NULL, 1, 0, ARRAY[]::int[]);
  FOR l IN 1..levels LOOP
    SELECT max(id) INTO n FROM seed;
    INSERT INTO seed (id, parent_id, ord, depth, sortkey)
    SELECT n + row_number() OVER (ORDER BY s.sortkey, g), s.id, g, l, s.sortkey || g
    FROM seed s, generate_series(1, fanout) g
    WHERE s.depth = l - 1;
  END LOOP;
  RETURN seed_finish();
END $$;

-- wide seed (spec 2.1, seat 4): a root with two sections. Section 1 holds
-- `wide` flat children (the grid shape, 1 x 10,000); section 2 holds 10
-- children and is the subtree the move op carries into section 1.
CREATE OR REPLACE FUNCTION seed_build_wide(wide int) RETURNS bigint
LANGUAGE plpgsql AS $$
BEGIN
  DROP TABLE IF EXISTS seed;
  CREATE TABLE seed (
    id bigint PRIMARY KEY, parent_id bigint, ord int NOT NULL,
    depth int NOT NULL, sortkey int[] NOT NULL, pre int, sz int);
  INSERT INTO seed (id, parent_id, ord, depth, sortkey) VALUES
    (0, NULL, 1, 0, ARRAY[]::int[]), (1, 0, 1, 1, ARRAY[1]), (2, 0, 2, 1, ARRAY[2]);
  INSERT INTO seed (id, parent_id, ord, depth, sortkey)
  SELECT 2 + g, 1, g, 2, ARRAY[1, g] FROM generate_series(1, wide) g;
  INSERT INTO seed (id, parent_id, ord, depth, sortkey)
  SELECT 2 + wide + g, 2, g, 2, ARRAY[2, g] FROM generate_series(1, 10) g;
  RETURN seed_finish();
END $$;

-- pre, sz and the sortkey index of the seed; returns the item count
CREATE OR REPLACE FUNCTION seed_finish() RETURNS bigint
LANGUAGE plpgsql AS $$
DECLARE
  n bigint;
BEGIN
  CREATE UNIQUE INDEX seed_sortkey ON seed (sortkey);
  UPDATE seed s SET pre = x.r
  FROM (SELECT id, row_number() OVER (ORDER BY sortkey) r FROM seed) x
  WHERE x.id = s.id;
  UPDATE seed s SET sz = x.c
  FROM (SELECT a.id, count(*) c
        FROM seed d
        CROSS JOIN LATERAL generate_series(0, d.depth) k
        JOIN seed a ON a.sortkey = d.sortkey[1:k]
        GROUP BY a.id) x
  WHERE x.id = s.id;
  ANALYZE seed;
  SELECT count(*) INTO n FROM seed;
  RETURN n;
END $$;

-- md5 of a subtree's ids in document order, from the seed: what every
-- model's read must return.
CREATE OR REPLACE FUNCTION seed_subtree_md5(x bigint) RETURNS text
LANGUAGE sql AS $$
  SELECT md5(string_agg(d.id::text, ',' ORDER BY d.pre))
  FROM seed s JOIN seed d ON d.pre BETWEEN s.pre AND s.pre + s.sz - 1
  WHERE s.id = x;
$$;

CREATE OR REPLACE FUNCTION seed_id(key int[]) RETURNS bigint
LANGUAGE sql AS $$ SELECT id FROM seed WHERE sortkey = key $$;

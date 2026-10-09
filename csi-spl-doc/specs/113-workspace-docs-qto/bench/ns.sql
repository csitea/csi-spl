-- spec 113 tree bench, model "ns": nested set (lft/rgt) plus parent_id and
-- depth, the classic structure with the parent link kept for the checks.

CREATE OR REPLACE FUNCTION ns_load() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  DROP TABLE IF EXISTS t_ns;
  CREATE TABLE t_ns (
    id bigint PRIMARY KEY,
    parent_id bigint,
    lft int NOT NULL,
    rgt int NOT NULL,
    depth int NOT NULL,
    title text NOT NULL,
    CHECK (abs(lft) < abs(rgt)),  -- a moved subtree parks on negatives
    CONSTRAINT t_ns_lft UNIQUE (lft) DEFERRABLE INITIALLY IMMEDIATE,
    CONSTRAINT t_ns_rgt UNIQUE (rgt) DEFERRABLE INITIALLY IMMEDIATE);
  -- preorder index i at depth d: lft = 2i - d - 1, rgt = lft + 2*size - 1
  INSERT INTO t_ns
  SELECT id, parent_id, 2 * pre - depth - 1, 2 * pre - depth - 1 + 2 * sz - 1, depth, 'item ' || id
  FROM seed ORDER BY pre;
  CREATE INDEX t_ns_parent ON t_ns (parent_id, lft);
END $$;

-- the lft a new child of p at position pos takes
CREATE OR REPLACE FUNCTION ns_slot(p bigint, pos int) RETURNS int
LANGUAGE plpgsql AS $$
DECLARE
  s int;
BEGIN
  IF pos <= 1 THEN
    SELECT lft + 1 INTO s FROM t_ns WHERE id = p;
    RETURN s;
  END IF;
  SELECT rgt + 1 INTO s FROM t_ns WHERE parent_id = p AND lft > 0
  ORDER BY lft OFFSET pos - 2 LIMIT 1;
  IF s IS NULL THEN
    SELECT rgt INTO s FROM t_ns WHERE id = p;
  END IF;
  RETURN s;
END $$;

CREATE OR REPLACE FUNCTION ns_insert(p bigint, pos int, newid bigint) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  s int;
BEGIN
  PERFORM pg_advisory_xact_lock(113);
  s := ns_slot(p, pos);
  UPDATE t_ns SET rgt = rgt + 2 WHERE rgt >= s;
  UPDATE t_ns SET lft = lft + 2 WHERE lft >= s;
  INSERT INTO t_ns VALUES (newid, p, s, s + 1, (SELECT depth + 1 FROM t_ns WHERE id = p), 'new');
END $$;

CREATE OR REPLACE FUNCTION ns_move(x bigint, newp bigint, pos int) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  xl int; xr int; xd int; w int;
  pl int; pd int; s int;
BEGIN
  PERFORM pg_advisory_xact_lock(113);
  SELECT lft, rgt, depth INTO xl, xr, xd FROM t_ns WHERE id = x;
  SELECT lft, depth INTO pl, pd FROM t_ns WHERE id = newp;
  PERFORM bench_assert(xd > 0, 'ns_move: root or missing item');
  PERFORM bench_assert(NOT (pl BETWEEN xl AND xr), 'ns_move: target inside the moved subtree');
  w := xr - xl + 1;
  -- park the subtree on negative numbers, close its gap, open the new one
  UPDATE t_ns SET lft = -lft, rgt = -rgt WHERE lft BETWEEN xl AND xr;
  UPDATE t_ns SET lft = lft - w WHERE lft > xr;
  UPDATE t_ns SET rgt = rgt - w WHERE rgt > xr;
  s := ns_slot(newp, pos);
  UPDATE t_ns SET rgt = rgt + w WHERE rgt >= s;
  UPDATE t_ns SET lft = lft + w WHERE lft >= s;
  UPDATE t_ns SET lft = -lft + (s - xl), rgt = -rgt + (s - xl), depth = depth + (pd + 1 - xd)
  WHERE lft < 0;
  UPDATE t_ns SET parent_id = newp WHERE id = x;
END $$;

CREATE OR REPLACE FUNCTION ns_read(x bigint)
RETURNS TABLE (rn bigint, id bigint, depth int, title text)
LANGUAGE sql STABLE AS $$
  SELECT row_number() OVER (ORDER BY t.lft), t.id, t.depth - s.depth, t.title
  FROM t_ns s JOIN t_ns t ON t.lft BETWEEN s.lft AND s.rgt
  WHERE s.id = x
  ORDER BY t.lft;
$$;

-- invariants: one root spanning 1..2N; the 2N bounds are 1..2N with no gap
-- or overlap; each item sits inside its parent one level down; siblings
-- tile their parent exactly (first = p.lft+1, next = prev.rgt+1, last
-- ends at p.rgt-1).
CREATE OR REPLACE FUNCTION ns_check() RETURNS void LANGUAGE plpgsql AS $$
DECLARE
  n bigint;
BEGIN
  SELECT count(*) INTO n FROM t_ns;
  PERFORM bench_assert((SELECT count(*) FROM t_ns WHERE parent_id IS NULL AND lft = 1 AND rgt = 2 * n) = 1,
    'ns: one root spanning 1..2N');
  PERFORM bench_assert((
    SELECT count(DISTINCT v) = 2 * n AND min(v) = 1 AND max(v) = 2 * n
    FROM (SELECT lft v FROM t_ns UNION ALL SELECT rgt FROM t_ns) b), 'ns: bounds are 1..2N');
  PERFORM bench_assert(NOT EXISTS (
    SELECT 1 FROM t_ns c JOIN t_ns p ON p.id = c.parent_id
    WHERE NOT (p.lft < c.lft AND c.rgt < p.rgt AND c.depth = p.depth + 1)), 'ns: inside parent');
  PERFORM bench_assert(NOT EXISTS (
    SELECT 1 FROM (
      SELECT c.lft, c.rgt, p.lft plft, p.rgt prgt,
             lag(c.rgt) OVER w prev_rgt, lead(c.lft) OVER w next_lft
      FROM t_ns c JOIN t_ns p ON p.id = c.parent_id
      WINDOW w AS (PARTITION BY c.parent_id ORDER BY c.lft)) s
    WHERE (prev_rgt IS NULL AND lft <> plft + 1)
       OR (prev_rgt IS NOT NULL AND lft <> prev_rgt + 1)
       OR (next_lft IS NULL AND rgt <> prgt - 1)), 'ns: siblings tile the parent');
END $$;

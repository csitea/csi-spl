-- spec 113 tree bench, model "adj": adjacency list + sibling ordinal.
-- Source of truth = parent_id + ord; the outline number is derived.

CREATE OR REPLACE FUNCTION adj_load() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  DROP TABLE IF EXISTS t_adj;
  CREATE TABLE t_adj (
    id bigint PRIMARY KEY,
    parent_id bigint REFERENCES t_adj (id),
    ord int NOT NULL CHECK (ord >= 1 OR ord = -1),
    title text NOT NULL,
    CONSTRAINT t_adj_sib UNIQUE (parent_id, ord) DEFERRABLE INITIALLY IMMEDIATE);
  INSERT INTO t_adj SELECT id, parent_id, ord, 'item ' || id FROM seed ORDER BY pre;
END $$;

CREATE OR REPLACE FUNCTION adj_insert(p bigint, pos int, newid bigint) RETURNS void
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM pg_advisory_xact_lock(113);
  UPDATE t_adj SET ord = ord + 1 WHERE parent_id = p AND ord >= pos;
  INSERT INTO t_adj VALUES (newid, p,
    least(pos, (SELECT count(*) + 1 FROM t_adj WHERE parent_id = p)), 'new');
END $$;

CREATE OR REPLACE FUNCTION adj_move(x bigint, newp bigint, pos int) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  oldp bigint;
  oldo int;
BEGIN
  PERFORM pg_advisory_xact_lock(113);
  SELECT parent_id, ord INTO oldp, oldo FROM t_adj WHERE id = x;
  PERFORM bench_assert(oldp IS NOT NULL, 'adj_move: root or missing item');
  PERFORM bench_assert(NOT EXISTS (
    WITH RECURSIVE up AS (
      SELECT id, parent_id FROM t_adj WHERE id = newp
      UNION ALL
      SELECT a.id, a.parent_id FROM t_adj a JOIN up ON a.id = up.parent_id)
    SELECT 1 FROM up WHERE id = x), 'adj_move: target inside the moved subtree');
  UPDATE t_adj SET ord = -1 WHERE id = x;
  UPDATE t_adj SET ord = ord - 1 WHERE parent_id = oldp AND ord > oldo;
  UPDATE t_adj SET ord = ord + 1 WHERE parent_id = newp AND ord >= pos;
  UPDATE t_adj SET parent_id = newp, ord = pos WHERE id = x;
END $$;

CREATE OR REPLACE FUNCTION adj_read(x bigint)
RETURNS TABLE (rn bigint, id bigint, depth int, title text)
LANGUAGE sql STABLE AS $$
  WITH RECURSIVE sub AS (
    SELECT a.id, 0 AS depth, ARRAY[a.ord] AS k, a.title FROM t_adj a WHERE a.id = x
    UNION ALL
    SELECT c.id, s.depth + 1, s.k || c.ord, c.title
    FROM t_adj c JOIN sub s ON c.parent_id = s.id)
  SELECT row_number() OVER (ORDER BY k), id, depth, title FROM sub ORDER BY k;
$$;

-- invariants: one root; siblings numbered 1..k with no gap or overlap;
-- every item reachable from the root (no cycle, no orphan).
CREATE OR REPLACE FUNCTION adj_check() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM bench_assert((SELECT count(*) FROM t_adj WHERE parent_id IS NULL) = 1, 'adj: one root');
  PERFORM bench_assert(NOT EXISTS (
    SELECT 1 FROM t_adj WHERE parent_id IS NOT NULL GROUP BY parent_id
    HAVING min(ord) <> 1 OR max(ord) <> count(*)), 'adj: sibling order 1..k');
  PERFORM bench_assert((
    WITH RECURSIVE r AS (
      SELECT id FROM t_adj WHERE parent_id IS NULL
      UNION ALL
      SELECT c.id FROM t_adj c JOIN r ON c.parent_id = r.id)
    SELECT count(*) FROM r) = (SELECT count(*) FROM t_adj), 'adj: all reachable');
END $$;

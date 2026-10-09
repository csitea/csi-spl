-- spec 113 tree bench, model "lt": ltree materialized path whose labels
-- ARE the outline number (r.00001.00003 = 1.3), so path order = doc order.

CREATE OR REPLACE FUNCTION lt_lbl(i int) RETURNS ltree
LANGUAGE sql IMMUTABLE AS $$ SELECT lpad(i::text, 5, '0')::ltree $$;

CREATE OR REPLACE FUNCTION lt_tail(path ltree, n int) RETURNS ltree
LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN nlevel(path) > n THEN subpath(path, n) ELSE ''::ltree END
$$;

CREATE OR REPLACE FUNCTION lt_load() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  DROP TABLE IF EXISTS t_lt;
  CREATE TABLE t_lt (
    id bigint PRIMARY KEY,
    path ltree NOT NULL,
    title text NOT NULL,
    CONSTRAINT t_lt_path UNIQUE (path) DEFERRABLE INITIALLY IMMEDIATE);
  INSERT INTO t_lt
  SELECT id,
         ('r' || CASE WHEN depth = 0 THEN ''
                      ELSE '.' || (SELECT string_agg(lpad(k::text, 5, '0'), '.' ORDER BY i)
                                   FROM unnest(sortkey) WITH ORDINALITY u (k, i)) END)::ltree,
         'item ' || id
  FROM seed ORDER BY pre;
  CREATE INDEX t_lt_path_gist ON t_lt USING gist (path);
END $$;

-- renumber the children of par with ordinal >= from_ord by delta, with
-- their whole subtrees
CREATE OR REPLACE FUNCTION lt_shift(par ltree, from_ord int, delta int) RETURNS void
LANGUAGE sql AS $$
  UPDATE t_lt
  SET path = par || lt_lbl(subpath(path, nlevel(par), 1)::text::int + delta)
             || lt_tail(path, nlevel(par) + 1)
  WHERE path <@ par AND nlevel(path) > nlevel(par)
    AND subpath(path, nlevel(par), 1)::text::int >= from_ord;
$$;

CREATE OR REPLACE FUNCTION lt_insert(p bigint, pos int, newid bigint) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  par ltree;
  n int;
BEGIN
  PERFORM pg_advisory_xact_lock(113);
  SELECT path INTO par FROM t_lt WHERE id = p;
  SELECT count(*) INTO n FROM t_lt WHERE path ~ (par::text || '.*{1}')::lquery;
  pos := least(pos, n + 1);
  PERFORM lt_shift(par, pos, 1);
  INSERT INTO t_lt VALUES (newid, par || lt_lbl(pos), 'new');
END $$;

CREATE OR REPLACE FUNCTION lt_move(x bigint, newp bigint, pos int) RETURNS void
LANGUAGE plpgsql AS $$
DECLARE
  xp ltree;
  np ltree;
BEGIN
  PERFORM pg_advisory_xact_lock(113);
  SELECT path INTO xp FROM t_lt WHERE id = x;
  SELECT path INTO np FROM t_lt WHERE id = newp;
  PERFORM bench_assert(nlevel(xp) > 1, 'lt_move: root or missing item');
  PERFORM bench_assert(NOT (np <@ xp), 'lt_move: target inside the moved subtree');
  UPDATE t_lt SET path = 'tmp' || lt_tail(path, nlevel(xp)) WHERE path <@ xp;
  PERFORM lt_shift(subpath(xp, 0, nlevel(xp) - 1), subpath(xp, nlevel(xp) - 1, 1)::text::int + 1, -1);
  SELECT path INTO np FROM t_lt WHERE id = newp;
  PERFORM lt_shift(np, pos, 1);
  UPDATE t_lt SET path = np || lt_lbl(pos) || lt_tail(path, 1) WHERE path <@ 'tmp';
END $$;

CREATE OR REPLACE FUNCTION lt_read(x bigint)
RETURNS TABLE (rn bigint, id bigint, depth int, title text)
LANGUAGE sql STABLE AS $$
  SELECT row_number() OVER (ORDER BY t.path), t.id, nlevel(t.path) - nlevel(s.path), t.title
  FROM t_lt s JOIN t_lt t ON t.path <@ s.path
  WHERE s.id = x
  ORDER BY t.path;
$$;

-- invariants: one root 'r'; every parent path exists; siblings numbered
-- 1..k with no gap or overlap.
CREATE OR REPLACE FUNCTION lt_check() RETURNS void LANGUAGE plpgsql AS $$
BEGIN
  PERFORM bench_assert((SELECT count(*) FROM t_lt WHERE path = 'r') = 1, 'lt: one root');
  PERFORM bench_assert(NOT EXISTS (SELECT 1 FROM t_lt WHERE NOT path <@ 'r'), 'lt: all under root');
  PERFORM bench_assert(NOT EXISTS (
    SELECT 1 FROM t_lt c WHERE nlevel(c.path) > 1
      AND NOT EXISTS (SELECT 1 FROM t_lt p WHERE p.path = subpath(c.path, 0, nlevel(c.path) - 1))),
    'lt: every parent exists');
  PERFORM bench_assert(NOT EXISTS (
    SELECT 1 FROM t_lt WHERE nlevel(path) > 1
    GROUP BY subpath(path, 0, nlevel(path) - 1)
    HAVING min(subpath(path, nlevel(path) - 1, 1)::text::int) <> 1
        OR max(subpath(path, nlevel(path) - 1, 1)::text::int) <> count(*)),
    'lt: sibling order 1..k');
END $$;

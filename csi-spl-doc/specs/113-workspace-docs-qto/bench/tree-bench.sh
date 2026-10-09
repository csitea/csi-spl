#!/usr/bin/env bash
# spec 113 tree bench: three tree models for workspace documents, timed in
# a throwaway Postgres container.
#
# models: adj (adjacency list + sibling ordinal), lt (ltree path = outline
# number), ns (nested set lft/rgt + parent_id). The SQL is in adj.sql,
# lt.sql, ns.sql next to this file; common.sql builds the seed tree.
#
# ops, each one plpgsql/sql call, timed with psql \timing inside ONE psql
# session per model:
#   insert  a new FIRST child of section 1     (worst case: early in the doc)
#   append  a new LAST child of the last section (best case: end of the doc)
#   move    the subtree 10.10 to the first child of section 1
#   read    the whole subtree of section 1, in document order
# sizes: fanout 10 at 3 and 4 levels = 1,111 and 11,111 items, and the
# wide parent 1x10000 (spec 2.1, seat 4): section 1 has 10,000 flat
# children, section 2 has 10 (10,013 items). There insert, append and the
# move target are all section 1, and the moved subtree is section 2.
# After each shape's load an untimed DIAG line (adj only) prints the
# sibling count under the insert parent and the rows the insert-first and
# the append shift (GET DIAGNOSTICS ROW_COUNT of adj_insert's UPDATE).
# Each write runs in BEGIN .. ROLLBACK, then VACUUM, so every repetition
# starts from the same tree. After each op the model's invariant check and
# the op's own result check run (untimed); any failure stops the run
# (ON_ERROR_STOP). Repetition 0 is a warm-up and is not counted.
# A control per model and shape plants a broken row and requires the check
# to catch it; in the wide shape it is a gap after the last of 10,000.
#
# usage:  bash tree-bench.sh
# env:    BENCH_REPS=5  BENCH_IMAGE=postgres:16-alpine  BENCH_CON=pg-s113-bench
#         BENCH_OUT=<raw output file, default raw-<utc>.txt next to this file>
# prints: the raw output path, then a markdown table of median/min/max ms;
#         size = item count, or 1x10000 for the wide parent.
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
reps=${BENCH_REPS:-5}
image=${BENCH_IMAGE:-postgres:16-alpine}
con=${BENCH_CON:-pg-s113-bench}
out=${BENCH_OUT:-$here/raw-$(date -u +%Y%m%dT%H%M%SZ).txt}

cleanup() { docker rm -f -v "$con" >/dev/null 2>&1 || true; }
trap cleanup EXIT

start_pg() {
  cleanup
  docker run -d --name "$con" -e POSTGRES_PASSWORD=bench "$image" >/dev/null
  for _ in $(seq 1 60); do
    if docker exec "$con" psql -U postgres -Atc 'SELECT 1' >/dev/null 2>&1; then
      sleep 2
      docker exec "$con" psql -U postgres -Atc 'SELECT 1' >/dev/null 2>&1 && return 0
    fi
    sleep 1
  done
  echo "FAIL: postgres in $con did not come up" >&2
  return 1
}

# the statement that breaks one invariant of model $1 in shape $2 (the control)
plant_bug() {
  case "$1 $2" in
    "adj wide") echo "UPDATE t_adj SET ord = 10001 WHERE id = seed_id('{1,10000}');" ;;
    "lt wide")  echo "UPDATE t_lt SET path = 'r.00001.10001' WHERE id = seed_id('{1,10000}');" ;;
    "ns wide")  echo "UPDATE t_ns SET rgt = rgt + 1 WHERE id = seed_id('{1,1}');" ;;
    "adj "*) echo "UPDATE t_adj SET ord = 99 WHERE id = seed_id('{1,10}');" ;;
    "lt "*)  echo "UPDATE t_lt SET path = 'r.00001.00099' WHERE id = seed_id('{1,1}');" ;;
    "ns "*)  echo "UPDATE t_ns SET rgt = rgt + 1 WHERE id = seed_id('{1,1,1}');" ;;
  esac
}

# untimed evidence for adj: siblings under the insert parent and the rows
# adj_insert's shifting UPDATE touches for insert-first and append
adj_diag() {
  cat <<'EOF'
SELECT set_config('bench.p_first', :'p_first', false), set_config('bench.p_last', :'p_last', false), set_config('bench.size', :'size', false);
BEGIN;
DO $$
DECLARE
  pf bigint := current_setting('bench.p_first')::bigint;
  pl bigint := current_setting('bench.p_last')::bigint;
  sf bigint; sl bigint; uf bigint; ul bigint;
BEGIN
  SELECT count(*) INTO sf FROM t_adj WHERE parent_id = pf;
  SELECT count(*) INTO sl FROM t_adj WHERE parent_id = pl;
  UPDATE t_adj SET ord = ord + 1 WHERE parent_id = pf AND ord >= 1;
  GET DIAGNOSTICS uf = ROW_COUNT;
  UPDATE t_adj SET ord = ord + 1 WHERE parent_id = pl AND ord >= 1000000;
  GET DIAGNOSTICS ul = ROW_COUNT;
  RAISE WARNING 'DIAG adj % insert siblings=% rows_updated=%', current_setting('bench.size'), sf, uf;
  RAISE WARNING 'DIAG adj % append siblings=% rows_updated=%', current_setting('bench.size'), sl, ul;
END $$;
ROLLBACK;
EOF
}

write_op() {
  local m=$1 op=$2 r=$3
  local newid=$((900000000 + r))
  case "$op" in
    insert)
      cat <<EOF
BEGIN;
\\echo BENCH $m :size insert $r
\\timing on
SELECT ${m}_insert(:p_first, 1, $newid);
\\timing off
SELECT ${m}_check();
SELECT bench_assert((SELECT count(*) FROM t_$m) = :n_total + 1, 'insert: count');
SELECT bench_assert((SELECT id FROM ${m}_read(:p_first) WHERE rn = 2) = $newid, 'insert: is the first child');
ROLLBACK;
VACUUM t_$m;
EOF
      ;;
    append)
      cat <<EOF
BEGIN;
\\echo BENCH $m :size append $r
\\timing on
SELECT ${m}_insert(:p_last, 1000000, $newid);
\\timing off
SELECT ${m}_check();
SELECT bench_assert((SELECT count(*) FROM t_$m) = :n_total + 1, 'append: count');
SELECT bench_assert((SELECT id FROM ${m}_read(:p_last) WHERE depth = 1 ORDER BY rn DESC LIMIT 1) = $newid, 'append: is the last child');
ROLLBACK;
VACUUM t_$m;
EOF
      ;;
    move)
      cat <<EOF
BEGIN;
\\echo BENCH $m :size move $r
\\timing on
SELECT ${m}_move(:x_move, :p_first, 1);
\\timing off
SELECT ${m}_check();
SELECT bench_assert((SELECT count(*) FROM t_$m) = :n_total, 'move: count');
SELECT bench_assert((SELECT id FROM ${m}_read(:p_first) WHERE rn = 2) = :x_move, 'move: is the first child');
SELECT bench_assert((SELECT md5(string_agg(id::text, ',' ORDER BY rn)) FROM ${m}_read(:x_move)) = :'move_md5', 'move: subtree intact');
ROLLBACK;
VACUUM t_$m;
EOF
      ;;
    read)
      cat <<EOF
\\echo BENCH $m :size read $r
\\timing on
SELECT * FROM ${m}_read(:p_first);
\\timing off
SELECT bench_assert((SELECT md5(string_agg(id::text, ',' ORDER BY rn)) FROM ${m}_read(:p_first)) = :'read_md5', 'read: document order');
SELECT bench_assert((SELECT count(*) FROM ${m}_read(:p_first)) = :read_n, 'read: count');
EOF
      ;;
  esac
}

# psql that builds the seed of shape $1 and sets n_total, size and the op
# targets p_first (insert, move target, read), p_last (append), x_move
seed_shape() {
  case "$1" in
    wide)
      cat <<'EOF'
SELECT seed_build_wide(10000) AS n_total \gset
\set size 1x10000
SELECT seed_id('{1}') AS p_first, seed_id('{1}') AS p_last, seed_id('{2}') AS x_move \gset
EOF
      ;;
    *)
      cat <<EOF
SELECT seed_build(10, $1) AS n_total \\gset
\\set size :n_total
SELECT seed_id('{1}') AS p_first, seed_id('{10}') AS p_last, seed_id('{10,10}') AS x_move \\gset
EOF
      ;;
  esac
}

write_session() {
  local m=$1 shape r op
  cat "$here/common.sql" "$here/$m.sql"
  echo '\o /dev/null'
  echo "SELECT version() AS pg_version \\gset"
  printf '%s\n' "\\echo MODEL $m :pg_version"
  for shape in 3 4 wide; do
    seed_shape "$shape"
    cat <<EOF
SELECT ${m}_load();
VACUUM ANALYZE t_$m;
SELECT ${m}_check();
SELECT seed_subtree_md5(:p_first) AS read_md5, seed_subtree_md5(:x_move) AS move_md5 \\gset
SELECT sz AS read_n FROM seed WHERE id = :p_first \\gset
\\echo LOADED $m size=:size items=:n_total read_n=:read_n
DO \$\$
BEGIN
  BEGIN
    $(plant_bug "$m" "$shape")
    PERFORM ${m}_check();
    RAISE EXCEPTION 'CONTROL NOT CAUGHT';
  EXCEPTION WHEN raise_exception OR unique_violation OR check_violation THEN
    IF SQLERRM = 'CONTROL NOT CAUGHT' THEN RAISE; END IF;
    RAISE WARNING 'CONTROL $m caught: %', SQLERRM;
  END;
END \$\$;
SELECT ${m}_check();
EOF
    if [ "$m" = adj ]; then adj_diag; fi
    for r in $(seq 0 "$reps"); do
      for op in insert append move read; do
        write_op "$m" "$op" "$r"
      done
    done
  done
}

summarize() {
  awk '
    $1 == "BENCH" { key = $2 " " $3 " " $4; rep = $5; next }
    $1 == "Time:" && key != "" {
      if (rep > 0) { v[key] = v[key] " " $2; if (!(key in seen)) { seen[key] = 1; order[++k] = key } }
      key = ""
    }
    END {
      print "| model | size | op | median ms | min ms | max ms | n |"
      print "|---|---:|---|---:|---:|---:|---:|"
      for (i = 1; i <= k; i++) {
        n = split(substr(v[order[i]], 2), a, " ")
        for (x = 2; x <= n; x++) { t = a[x]; y = x - 1; while (y > 0 && a[y] + 0 > t + 0) { a[y + 1] = a[y]; y-- } a[y + 1] = t }
        med = (n % 2) ? a[(n + 1) / 2] : (a[n / 2] + a[n / 2 + 1]) / 2
        split(order[i], f, " ")
        printf "| %s | %s | %s | %.3f | %.3f | %.3f | %d |\n", f[1], f[2], f[3], med, a[1], a[n], n
      }
    }' "$1"
}

main() {
  start_pg
  {
    echo "# spec 113 tree bench raw output"
    echo "# utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) image=$image reps=$reps nproc=$(nproc)"
    echo "# tree=$(git -C "$here" rev-parse --short HEAD 2>/dev/null || echo none) bench-md5=$(cd "$here" && cat common.sql adj.sql lt.sql ns.sql tree-bench.sh | md5sum | cut -d' ' -f1)"
    echo "# uptime:$(uptime)"
  } > "$out"
  local m
  for m in adj lt ns; do
    if ! write_session "$m" | docker exec -i "$con" psql -U postgres -X -q -v ON_ERROR_STOP=1 -f - >> "$out" 2>&1; then
      echo "FAIL: model $m stopped, see $out" >&2
      tail -n 5 "$out" >&2
      return 1
    fi
  done
  echo "# uptime-after:$(uptime)" >> "$out"
  echo "raw: $out"
  summarize "$out"
}

main "$@"

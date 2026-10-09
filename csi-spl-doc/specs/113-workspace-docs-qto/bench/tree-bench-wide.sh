#!/usr/bin/env bash
# spec 113 tree bench: adjacency list model, wide-parent case (1 x 10,000)

set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
reps=${BENCH_REPS:-5}
image=${BENCH_IMAGE:-postgres:16-alpine}
con=${BENCH_CON:-pg-s113-m-621}
out=${BENCH_OUT:-$here/raw-$(date -u +%Y%m%dT%H%M%SZ).txt}

cleanup() { docker rm -f -v "$con" >/dev/null 2>&1 || true; }
trap cleanup EXIT

start_pg() {
  cleanup
  docker run -d --name "$con" -e POSTGRES_PASSWORD=bench "$image" >/dev/null
  for _ in $(seq 1 60); do
    if docker exec "$con" psql -U postgres -Atc "SELECT 1" >/dev/null 2>&1; then
      sleep 2
      docker exec "$con" psql -U postgres -Atc "SELECT 1" >/dev/null 2>&1 && return 0
    fi
    sleep 1
  done
  echo "FAIL: postgres in $con did not come up" >&2
  return 1
}

write_op_insert() {
  echo "BEGIN;"
  echo "\echo BENCH adj :n_total insert 0"
  echo "\timing on"
  echo "SELECT adj_insert(:p_first, 1, 900000000);"
  echo "\timing off"
  echo "SELECT adj_check();"
  echo "SELECT bench_assert((SELECT count(*) FROM t_adj) = :n_total + 1, 'insert: count');"
  echo "SELECT bench_assert((SELECT id FROM adj_read(:p_first) WHERE rn = 2) = 900000000, 'insert: is the first child');"
  echo "ROLLBACK;"
  echo "VACUUM t_adj;"
}

write_op_append() {
  echo "BEGIN;"
  echo "\echo BENCH adj :n_total append 0"
  echo "\timing on"
  echo "SELECT adj_insert(:p_last, 1000000, 900000000);"
  echo "\timing off"
  echo "SELECT adj_check();"
  echo "SELECT bench_assert((SELECT count(*) FROM t_adj) = :n_total + 1, 'append: count');"
  echo "SELECT bench_assert((SELECT id FROM adj_read(:p_last) WHERE depth = 1 ORDER BY rn DESC LIMIT 1) = 900000000, 'append: is the last child');"
  echo "ROLLBACK;"
  echo "VACUUM t_adj;"
}

write_op_move() {
  echo "BEGIN;"
  echo "\echo BENCH adj :n_total move 0"
  echo "\timing on"
  echo "SELECT adj_check();"

  echo "SELECT adj_check();"
  echo "ROLLBACK;"
  echo "VACUUM t_adj;"
}

write_op_read() {
  echo "\echo BENCH adj :n_total read 0"
  echo "\timing on"
  echo "SELECT * FROM adj_read(:p_first);"
  echo "\timing off"
  echo "SELECT bench_assert((SELECT md5(string_agg(id::text, ',' ORDER BY rn)) FROM adj_read(:p_first)) = :'read_md5', 'read: document order');"
  echo "SELECT bench_assert((SELECT count(*) FROM adj_read(:p_first)) = :read_n, 'read: count');"
}

write_session() {
  cat "$here/common.sql" "$here/adj.sql"
  echo '\o /dev/null'
  echo "SELECT version() AS pg_version \gset"
  echo "\echo MODEL adj :pg_version"
  echo "SELECT seed_build(1, 1) AS n_total \gset"
  echo "SELECT adj_load();"
  echo "VACUUM ANALYZE t_adj;"
  echo "SELECT adj_check();"
  echo "SELECT seed_id('{1}') AS p_first, seed_id('{1}') AS p_last, seed_id('{1}') AS x_move \gset"
  echo "SELECT seed_subtree_md5(:p_first) AS read_md5, seed_subtree_md5(:x_move) AS move_md5 \gset"
  echo "SELECT sz AS read_n FROM seed WHERE id = :p_first \gset"
  echo "\echo LOADED adj items=:n_total read_n=:read_n"
  echo "DO \$\$"
  echo "BEGIN"
  echo "  BEGIN"
  echo "    UPDATE t_adj SET ord = 99 WHERE id = seed_id('{1}');"
  echo "    PERFORM adj_check();"
  echo "    RAISE EXCEPTION 'CONTROL NOT CAUGHT';"
  echo "  EXCEPTION WHEN raise_exception OR unique_violation OR check_violation THEN"
  echo "    IF SQLERRM = 'CONTROL NOT CAUGHT' THEN RAISE; END IF;"
  echo "    RAISE WARNING 'CONTROL adj caught: %', SQLERRM;"
  echo "  END;"
  echo "END \$\$;"
  echo "SELECT adj_check();"
  for r in $(seq 0 "$reps"); do
    write_op_insert
    write_op_append
    write_op_move
    write_op_read
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
      print "| model | items | op | median ms | min ms | max ms | n |"
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
    echo "# spec 113 tree bench raw output (wide-parent case)"
    echo "# utc=$(date -u +%Y-%m-%dT%H:%M:%SZ) image=$image reps=$reps nproc=$(nproc)"
    echo "# uptime:$(uptime)"
  } > "$out"
  if ! write_session | docker exec -i "$con" psql -U postgres -X -q -v ON_ERROR_STOP=1 -f - >> "$out" 2>&1; then
    echo "FAIL: see $out" >&2
    tail -n 5 "$out" >&2
    return 1
  fi
  echo "# uptime-after:$(uptime)" >> "$out"
  echo "raw: $out"
  summarize "$out"
}

main "$@"

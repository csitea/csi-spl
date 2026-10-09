#!/usr/bin/env bash
# spec 113 tree bench: adjacency list model, wide-parent case (1 x 10,000)

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
reps=${BENCH_REPS:-5}
image=${BENCH_IMAGE:-postgres:16-alpine}
con=${BENCH_CON:-pg-s113-m-621}
out=${BENCH_OUT:-$here/raw-$(date -u +%Y%m%dT%H%M%SZ).txt}

cleanup() { docker rm -f -v "$con" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "Starting benchmark..." >&2

start_pg() {
  cleanup
  echo "Starting PostgreSQL container..." >&2
  docker run -d --name "$con" -e POSTGRES_PASSWORD=bench "$image" >/dev/null
  for _ in $(seq 1 60); do
    if docker exec "$con" psql -U postgres -Atc "SELECT 1" >/dev/null 2>&1; then
      sleep 2
      if docker exec "$con" psql -U postgres -Atc "SELECT 1" >/dev/null 2>&1; then
        echo "PostgreSQL container is ready." >&2
        return 0
      fi
    fi
    sleep 1
  done
  echo "FAIL: postgres in $con did not come up" >&2
  return 1
}

main() {
  start_pg
  {
    echo "# spec 113 tree bench raw output (wide-parent case)"
    echo "# utc=$(date -u +%Y-%m-%dT%H%M%SZ) image=$image reps=$reps nproc=$(nproc)"
    echo "# uptime:$(uptime)"
  } > "$out"

  echo "Copying SQL files to container..." >&2
  docker cp "$here/common.sql" "$con:/common.sql"
  docker cp "$here/adj.sql" "$con:/adj.sql"

  echo "Running SQL benchmark..." >&2
  docker exec -i "$con" psql -U postgres -X -q -v ON_ERROR_STOP=1 << 'SQL' >> "$out" 2>&1
    -- Load common.sql and adj.sql
    \i /common.sql
    \i /adj.sql

    -- Build wide seed
    SELECT seed_build(1, 1);
    TRUNCATE seed;
    INSERT INTO seed (id, parent_id, ord, depth, sortkey)
    SELECT 10000 + g, 0, g, 1, ARRAY[g]
    FROM generate_series(1, 10000) g;
    INSERT INTO seed (id, parent_id, ord, depth, sortkey) VALUES (0, NULL, 1, 0, '{}');

    -- Load into t_adj
    SELECT adj_load();
    VACUUM ANALYZE t_adj;
    SELECT adj_check();

    -- Control
    DO $$
    BEGIN
      BEGIN
        UPDATE t_adj SET ord = 99 WHERE id = (SELECT id FROM seed WHERE sortkey = '{1}');
        PERFORM adj_check();
        RAISE EXCEPTION 'CONTROL NOT CAUGHT';
      EXCEPTION WHEN raise_exception OR unique_violation OR check_violation THEN
        IF SQLERRM = 'CONTROL NOT CAUGHT' THEN RAISE; END IF;
        RAISE WARNING 'CONTROL adj caught: %', SQLERRM;
      END;
    END $$;
    SELECT adj_check();

    -- Benchmark
    DO $$
    DECLARE
      r int;
      p_first bigint;
      p_last bigint;
    BEGIN
      SELECT id FROM seed WHERE sortkey = '{}' INTO p_first;
      SELECT id FROM seed WHERE sortkey = '{}' INTO p_last;
      FOR r IN 1..5 LOOP
        -- Insert
        \timing on
        RAISE NOTICE 'BENCH adj % insert 0', (SELECT count(*) FROM t_adj);
        BEGIN
          PERFORM adj_insert(p_first, 1, 900000000);
          ROLLBACK;
        END;
        \timing off

        -- Append
        \timing on
        RAISE NOTICE 'BENCH adj % append 0', (SELECT count(*) FROM t_adj);
        BEGIN
          PERFORM adj_insert(p_last, 1000000, 900000000);
          ROLLBACK;
        END;
        \timing off

        -- Read
        \timing on
        RAISE NOTICE 'BENCH adj % read 0', (SELECT count(*) FROM t_adj);
        PERFORM adj_read(p_first);
        \timing off
      END LOOP;
    END $$;
SQL

  if [ $? -ne 0 ]; then
    echo "FAIL: see $out" >&2
    tail -n 5 "$out" >&2
    return 1
  fi

  echo "# uptime-after:$(uptime)" >> "$out"
  echo "raw: $out"

  awk '
    $0 ~ /BENCH adj/ { key = "adj " $4 " " $5; rep = $6; next }
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
        printf "| %s | %s | %s | %.3f | %.3f | %.3f | %d |\\n", f[1], f[2], f[3], med, a[1], a[n], n
      }
    }' "$out"
}

main "$@"

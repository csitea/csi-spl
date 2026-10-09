#!/bin/bash
# isolation-bench.sh - spec 114 sections 2 and 3: measure the three isolation
# models and prove the model (a) share grant, in ONE throwaway
# postgres:16-alpine started with Cloud SQL db-f1-micro's max_connections 25.
# Nothing here touches a cloud env. Prints PASS / CONTROL / M<n> lines.
#
#   BENCH_N="6 100"  workspace counts to measure
#   BENCH_REPS=3     repeats per timed migration / query (median printed)
#
# Usage: bash csi-spl-doc/specs/114-workspace-doc-privacy-sharing/bench/isolation-bench.sh
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
repo=$(git -C "$here" rev-parse --show-toplevel)
mig="$repo/csi-spl-rdb/src/sql/postgres/spool-hub/0157_workspace_docs.sql"
read -r -a ns <<< "${BENCH_N:-6 100}"
reps="${BENCH_REPS:-3}"
name="spl114-bench-$$"

docker run -d --rm --name "$name" -e POSTGRES_PASSWORD=bench postgres:16-alpine \
  -c max_connections=25 >/dev/null
trap 'docker rm -f "$name" >/dev/null 2>&1 || true' EXIT
# pg_isready lies during initdb (the temp server is socket-only): probe TCP.
for _ in $(seq 1 60); do
  docker exec -e PGPASSWORD=bench "$name" psql -X -q -h 127.0.0.1 -U postgres -c 'SELECT 1' >/dev/null 2>&1 && break
  sleep 1
done
docker exec "$name" mkdir -p /b
for f in "$mig" "$here"/share-grant.sql "$here"/share-proof.sql "$here"/share-control.sql; do
  docker cp "$f" "$name:/b/$(basename "$f")" >/dev/null
done

pg() { docker exec -i "$name" psql -X -q -v ON_ERROR_STOP=1 "$@"; }
now_ms() { echo $(( $(date +%s%N) / 1000000 )); }
median() { tr ' ' '\n' | sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }
# One database owned by the non-superuser spl_owner, so FORCE RLS binds it.
mkdb() {
  pg -U postgres -c "CREATE DATABASE $1 OWNER spl_owner"
  pg -U spl_owner -d "$1" -c 'CREATE TABLE tenants (tenant_id text PRIMARY KEY)'
}

echo "M0 $(docker exec "$name" postgres --version) load=$(cut -d' ' -f1 /proc/loadavg) cpus=$(nproc) reps=$reps"
pg -U postgres -c 'CREATE ROLE spl_owner LOGIN'

# --- section 3.4: the model (a) proof and its two controls -----------------
mkdb proof
pg -U spl_owner -d proof -c "INSERT INTO tenants VALUES ('a'), ('b'), ('c')"
pg -U spl_owner -d proof -f /b/0157_workspace_docs.sql -f /b/share-grant.sql
proof=$(pg -U spl_owner -d proof -f /b/share-proof.sql 2>&1 | sed -n 's/^.*NOTICE:  //p; /ERROR/p')
echo "$proof"
controls=$(pg -U postgres -d proof -t -A -v control=c1 -f /b/share-control.sql | grep CONTROL)$'\n'
for c in c2 c3 c4 c5 c6 c7 c8 c9 c10 c11; do
  controls+=$(pg -U spl_owner -d proof -t -A -v control="$c" -f /b/share-control.sql 2>&1 | grep -E 'CONTROL|ERROR' || echo "CONTROL $c MISSED (no output)")$'\n'
done
printf '%s' "$controls"
echo "SUMMARY pass=$(grep -c '^PASS' <<< "$proof") controls_caught=$(grep -c 'caught' <<< "$controls") of 11"

# M5: the ALTER fan-out timed INSIDE Postgres (clock_timestamp, a COMMIT per
# statement as a migration run does), so the docker exec + psql start every
# pg() call pays is not in it (c-715 #1). exec_noop = that client cost alone.
noop=$(for _ in $(seq 1 "$reps"); do s=$(now_ms); pg -U postgres -c 'SELECT 1' >/dev/null; echo $(( $(now_ms) - s )); done | median)
echo "M5 exec_noop_ms=$noop load=$(cut -d' ' -f1 /proc/loadavg)"
srv_alter() {
  pg -U spl_owner -d "$1" -t -A 2>&1 <<SQL | sed -n 's/^.*NOTICE:  ms=//p'
CREATE PROCEDURE pg_temp.bench_alter(nsch int) LANGUAGE plpgsql AS \$p\$
DECLARE t0 timestamptz := clock_timestamp(); tbl text;
BEGIN
  FOR i IN 1..greatest(nsch, 1) LOOP
    tbl := CASE WHEN nsch = 0 THEN 'workspace_doc' ELSE format('ws_%s.workspace_doc', i) END;
    EXECUTE format('ALTER TABLE %s ADD COLUMN bench_x text', tbl); COMMIT;
    EXECUTE format('ALTER TABLE %s DROP COLUMN bench_x', tbl); COMMIT;
  END LOOP;
  RAISE NOTICE 'ms=%', round(extract(epoch FROM clock_timestamp() - t0)::numeric * 1000, 1);
END \$p\$;
CALL pg_temp.bench_alter($2);
SQL
}

for n in "${ns[@]}"; do
  # --- M1 model (a): one set of tables, n tenant rows ----------------------
  mkdb "a$n"
  pg -U spl_owner -d "a$n" -c "INSERT INTO tenants SELECT 'w' || g FROM generate_series(1, $n) g"
  t0=$(now_ms); pg -U spl_owner -d "a$n" -f /b/0157_workspace_docs.sql -f /b/share-grant.sql; t1=$(now_ms)
  alter=$(for _ in $(seq 1 "$reps"); do
    s=$(now_ms)
    pg -U spl_owner -d "a$n" -c 'ALTER TABLE workspace_doc ADD COLUMN bench_x text' -c 'ALTER TABLE workspace_doc DROP COLUMN bench_x'
    echo $(( $(now_ms) - s ))
  done | median)
  rel=$(pg -U spl_owner -d "a$n" -t -A -c "SELECT count(*) FROM pg_class WHERE relnamespace = 'public'::regnamespace")
  echo "M1 model=a n=$n create_ms=$((t1 - t0)) alter_fanout_ms=$alter relations=$rel"

  # --- M2 model (b): a schema per workspace --------------------------------
  mkdb "b$n"
  pg -U postgres -c "GRANT CREATE ON DATABASE b$n TO spl_owner"
  for i in $(seq 1 "$n"); do
    printf 'CREATE SCHEMA ws_%s;\nSET search_path = ws_%s, public;\n\\i /b/0157_workspace_docs.sql\n' "$i" "$i"
  done > "/tmp/$name-b.sql"
  docker cp "/tmp/$name-b.sql" "$name:/b/b.sql" >/dev/null
  t0=$(now_ms); pg -U spl_owner -d "b$n" -f /b/b.sql; t1=$(now_ms)
  for i in $(seq 1 "$n"); do
    printf 'ALTER TABLE ws_%s.workspace_doc ADD COLUMN bench_x text;\nALTER TABLE ws_%s.workspace_doc DROP COLUMN bench_x;\n' "$i" "$i"
  done > "/tmp/$name-b.sql"
  docker cp "/tmp/$name-b.sql" "$name:/b/b-alter.sql" >/dev/null
  rm -f "/tmp/$name-b.sql"
  alter=$(for _ in $(seq 1 "$reps"); do
    s=$(now_ms); pg -U spl_owner -d "b$n" -f /b/b-alter.sql; echo $(( $(now_ms) - s ))
  done | median)
  rel=$(pg -U spl_owner -d "b$n" -t -A -c "SELECT count(*) FROM pg_class c JOIN pg_namespace s ON s.oid = c.relnamespace WHERE s.nspname LIKE 'ws\_%'")
  # the search_path trap (c-715 #3): 0157's trigger functions copied into a
  # schema carry no SET search_path, so they resolve tables via the caller's.
  unpinned=$(pg -U spl_owner -d "b$n" -t -A -c "SELECT count(*) FROM pg_proc WHERE pronamespace = 'ws_1'::regnamespace AND proconfig IS NULL")
  echo "M2 model=b n=$n create_ms=$((t1 - t0)) alter_fanout_ms=$alter relations=$rel db_bytes=$(pg -U postgres -t -A -c "SELECT pg_database_size('b$n')") ws_1_fns_without_search_path=$unpinned"
  srva=$(for _ in $(seq 1 "$reps"); do srv_alter "a$n" 0; done | median)
  srvb=$(for _ in $(seq 1 "$reps"); do srv_alter "b$n" "$n"; done | median)
  echo "M5 n=$n alter_server_ms model=a $srva model=b $srvb ($((2 * n)) statements)"

  # --- M3 model (c): a database per workspace ------------------------------
  t0=$(now_ms)
  for i in $(seq 1 "$n"); do
    mkdb "c${n}_$i"
    pg -U spl_owner -d "c${n}_$i" -f /b/0157_workspace_docs.sql
  done
  t1=$(now_ms)
  alter=$(for _ in $(seq 1 "$reps"); do
    s=$(now_ms)
    for i in $(seq 1 "$n"); do
      pg -U spl_owner -d "c${n}_$i" -c 'ALTER TABLE workspace_doc ADD COLUMN bench_x text' -c 'ALTER TABLE workspace_doc DROP COLUMN bench_x'
    done
    echo $(( $(now_ms) - s ))
  done | median)
  bytes=$(pg -U postgres -t -A -c "SELECT sum(pg_database_size(datname)) FROM pg_database WHERE datname LIKE 'c${n}\_%'")
  echo "M3 model=c n=$n create_ms=$((t1 - t0)) alter_fanout_ms=$alter db_bytes=$bytes"
  # one idle connection per workspace database, held 3 s: how many get in
  pids=(); for i in $(seq 1 "$n"); do
    pg -U spl_owner -d "c${n}_$i" -c 'SELECT pg_sleep(3)' >/dev/null 2>&1 & pids+=($!)
  done
  okc=0; for p in "${pids[@]}"; do wait "$p" && okc=$((okc + 1)); done
  echo "M3 model=c n=$n one_conn_per_db connected=$okc refused=$((n - okc)) max_connections=25"
done

# --- M4 model (a) at 100 workspaces x 1 doc x 1,111 items: share policy cost
mkdb q
pg -U spl_owner -d q -c "INSERT INTO tenants SELECT 'w' || g FROM generate_series(1, 100) g"
pg -U spl_owner -d q -f /b/0157_workspace_docs.sql -f /b/share-grant.sql
pg -U spl_owner -d q <<'SQL'
SET app.rls_scope = 'operator';
BEGIN;
INSERT INTO workspace_doc (id, tenant_id, title)
    SELECT md5(tenant_id || '/doc')::uuid, tenant_id, 'doc' FROM tenants;
INSERT INTO workspace_doc_item (id, tenant_id, doc_id, parent_id, ord, title)
    SELECT md5(tenant_id || '/r')::uuid, tenant_id, md5(tenant_id || '/doc')::uuid, NULL, 1, 'root' FROM tenants
    UNION ALL
    SELECT md5(tenant_id || '/' || a)::uuid, tenant_id, md5(tenant_id || '/doc')::uuid,
           md5(tenant_id || '/r')::uuid, a, 'l1'
      FROM tenants, generate_series(1, 10) a
    UNION ALL
    SELECT md5(tenant_id || '/' || a || '.' || b)::uuid, tenant_id, md5(tenant_id || '/doc')::uuid,
           md5(tenant_id || '/' || a)::uuid, b, 'l2'
      FROM tenants, generate_series(1, 10) a, generate_series(1, 10) b
    UNION ALL
    SELECT md5(tenant_id || '/' || a || '.' || b || '.' || c)::uuid, tenant_id, md5(tenant_id || '/doc')::uuid,
           md5(tenant_id || '/' || a || '.' || b)::uuid, c, 'l3'
      FROM tenants, generate_series(1, 10) a, generate_series(1, 10) b, generate_series(1, 10) c;
INSERT INTO workspace_doc_share (tenant_id, doc_id, to_tenant, access, granted_by, accepted_at, accepted_by)
    SELECT 'w' || g, md5('w' || g || '/doc')::uuid, 'w1', 'read', 'bench', now(), 'bench' FROM generate_series(2, 6) g;
COMMIT;
ANALYZE workspace_doc;
ANALYZE workspace_doc_item;
ANALYZE workspace_doc_share;
SQL
# $1 = the statement, timed as w1 (owner of w1's doc, reader of w2..w6's).
q4() {
  pg -U spl_owner -d q -t -A -c "SET app.tenant_id = 'w1'" -c "EXPLAIN (ANALYZE, COSTS OFF) $1" \
    | awk '/Execution Time/ {print $3} /Scan/ && !/workspace_doc_share/ && !s {sub(/^[ ->]+/, ""); sub(/ \(.*/, ""); s = $0} END {print s}'
}
declare -A query=(
  [own]="SELECT count(*) FROM workspace_doc_item WHERE doc_id = md5('w1/doc')::uuid"
  [shared]="SELECT count(*) FROM workspace_doc_item WHERE doc_id = md5('w2/doc')::uuid"
  [list]="SELECT count(*) FROM workspace_doc"
)
for policy in with-share without-share; do
  if [[ "$policy" == without-share ]]; then
    pg -U spl_owner -d q -c 'DROP POLICY share_read ON workspace_doc_item' -c 'DROP POLICY share_edit ON workspace_doc_item' \
      -c 'DROP POLICY share_read ON workspace_doc'
  fi
  for q in own shared list; do
    out=$(for _ in $(seq 1 "$reps"); do q4 "${query[$q]}"; done)
    ms=$(grep -E '^[0-9.]+$' <<< "$out" | median)
    scan=$(grep -vE '^[0-9.]+$' <<< "$out" | sed -n 1p)
    rows=$(pg -U spl_owner -d q -t -A -c "SET app.tenant_id = 'w1'" -c "${query[$q]}" | tail -1)
    echo "M4 model=a items=111100 policy=$policy query=$q rows=$rows median_ms=$ms scan=\"$scan\""
  done
done

#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_doc_tree_check (spec 113 section 3.4, T003).
#   A. the action, stubbed (no cloud call): a malformed DOC_ID is refused
#      before any gcloud call
#   B. the check SQL against a REAL throwaway Postgres with every rdb
#      migration, read by the RUNTIME login (non-owner, FORCE RLS binds), two
#      docs in two tenants:
#      1. clean: violations=0 docs=2 items=<n>, exit 0 (operator scope sees
#         both tenants)
#      2. one planted gap and one unreachable cycle (written by the owner with
#         the triggers off): both reported, the cycle named by its smallest
#         id, violations=2, exit 1
#      3. DOC_ID: the other doc alone is clean, docs=1, exit 0
#      4. CONTROL no operator scope: docs=0, exit 2; EXPECT_EMPTY=1: exit 0
#      5. CONTROL each planted defect is caught by its own query: with the
#         I4 (resp. I3) query neutered, that violation is gone and 2 fails
#   SKIP part B when no docker / psql / cached postgres image.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# A ---------------------------------------------------------------------------
orc_stub 1 gcloud docker
: >"$T/calls.log"
out=$(SNIPPET=do_spl_doc_tree_check in_orc DOC_ID="not-a-uuid" 2>&1); rc=$?
[[ $rc -ne 0 && ! -s "$T/calls.log" ]] && grep -q 'DOC_ID must be a lowercase uuid' <<<"$out" &&
  pass "A. a malformed DOC_ID is refused before any cloud call" || fail "A. rc=$rc calls=$(cat "$T/calls.log") $out"

# B ---------------------------------------------------------------------------
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! command -v psql >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  echo "SKIP: part B, no docker / psql / cached $PG_IMAGE image"
  (( fails == 0 )) && { echo "ALL PASS"; exit 0; }; echo "$fails FAILED"; exit 1
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-doc-check-pg-$$"
trap 'docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"' EXIT
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
PGPORT="$(docker port "$PG_CTR" 5432 | sed -n 1p | sed 's/.*://')"
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }
q() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" -c "$1"; }
q "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 "$OWNER_DSN" -v runtime_role=spool_rt \
  -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }
for t in t1 t2; do
  q "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('$t', decode(repeat('ab', 32), 'hex'))" >/dev/null
done

# The functions under test, with the orc libs (spl_pg_env) and a plain do_log.
do_log() { echo "$*"; }
for f in "$PROJ_ROOT"/lib/bash/funcs/spl-cloud-cnf.func.sh "$PROJ_ROOT"/src/bash/run/spl-doc-tree-check.func.sh; do
  # shellcheck source=/dev/null
  source "$f"
done

uuid() { cat /proc/sys/kernel/random/uuid; }
# mkdoc <tenant>: doc D, root R, children A(1) B(2) C(3), A with child A1(1),
# committed through the triggers by the owner.
mkdoc() {
  D=$(uuid) R=$(uuid) A=$(uuid) B=$(uuid) C=$(uuid) A1=$(uuid)
  q "BEGIN; INSERT INTO workspace_doc (id, tenant_id, title) VALUES ('$D', '$1', 'doc');
INSERT INTO workspace_doc_item (id, tenant_id, doc_id, parent_id, ord, title) VALUES
 ('$R','$1','$D',NULL,1,'root'),('$A','$1','$D','$R',1,'A'),('$B','$1','$D','$R',2,'B'),
 ('$C','$1','$D','$R',3,'C'),('$A1','$1','$D','$A',1,'A1'); COMMIT;" >/dev/null || { fail "mkdoc $1"; exit 1; }
}
# plant <sql>: as the owner with the triggers and FKs off (replica role), the
# way a broken row would get past them.
plant() { q "BEGIN; SET LOCAL session_replication_role = replica; $1 COMMIT;" >/dev/null; }

mkdoc t2; D2=$D
mkdoc t1

# --- 1. clean ------------------------------------------------------------------
out=$(spl_doc_tree_check_exec "$RT_DSN" operator 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qx 'violations=0 docs=2 items=10' <<<"$out" &&
  pass "1. clean: violations=0 docs=2 items=10, exit 0" || fail "1. rc=$rc $out"

# --- 2. a gap and an unreachable cycle --------------------------------------------
X=$(uuid)
plant "UPDATE workspace_doc_item SET ord = 2 WHERE id = '$A1';
INSERT INTO workspace_doc_item (id, tenant_id, doc_id, parent_id, ord, title) VALUES ('$X','t1','$D','$C',1,'X');
UPDATE workspace_doc_item SET parent_id = '$X', ord = 1 WHERE id = '$C';"
CUT=$(printf '%s\n%s\n' "$C" "$X" | sort | sed -n 1p)
check_planted() {
  local out rc=0
  out=$(spl_doc_tree_check_exec "$RT_DSN" operator 2>&1) || rc=$?
  [[ $rc -eq 1 ]] && grep -qx 'violations=2 docs=2 items=11' <<<"$out" &&
    grep -qx "violation I4 gap doc=$D parent=$A count=1 ord=2..2" <<<"$out" &&
    grep -qx "violation I3 cycle doc=$D cut=$CUT size=2" <<<"$out" || { echo "rc=$rc $out"; return 1; }
  echo "$out"
}
if out=$(check_planted); then pass "2. gap + cycle reported (cut=$CUT), violations=2, exit 1"; echo "$out" | sed 's/^/    /'
else fail "2. $out"; fi

# --- 3. DOC_ID -----------------------------------------------------------------------
out=$(spl_doc_tree_check_exec "$RT_DSN" operator "$D2" 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qx 'violations=0 docs=1 items=5' <<<"$out" &&
  pass "3. DOC_ID of the clean doc: docs=1, exit 0" || fail "3. rc=$rc $out"

# --- 4. CONTROL no operator scope ---------------------------------------------------
out=$(spl_doc_tree_check_exec "$RT_DSN" '' 2>&1); rc=$?
[[ $rc -eq 2 ]] && grep -qx 'violations=0 docs=0 items=0' <<<"$out" &&
  pass "4. CONTROL no operator scope: docs=0, exit 2" || fail "4. rc=$rc $out"
out=$(EXPECT_EMPTY=1 spl_doc_tree_check_exec "$RT_DSN" '' 2>&1); rc=$?
[[ $rc -eq 0 ]] && grep -qx 'violations=0 docs=0 items=0' <<<"$out" &&
  pass "4. EXPECT_EMPTY=1: docs=0, exit 0" || fail "4. EXPECT_EMPTY rc=$rc $out"

# --- 5. CONTROL each defect is caught by its own query --------------------------------
eval "$(declare -f spl_doc_tree_check_sql | sed '1s/spl_doc_tree_check_sql/_check_sql_real/')"
for inv in I4 I3; do
  case $inv in
    I4) neuter="s/^HAVING min(i.ord) <> 1 OR/HAVING false AND/" ;;
    I3) neuter="s/^  WHERE NOT EXISTS (SELECT 1 FROM reach WHERE reach.id = i.id)/  WHERE false/" ;;
  esac
  [[ "$(_check_sql_real | sed "$neuter")" != "$(_check_sql_real)" ]] || fail "5. CONTROL $inv: the neuter matched nothing"
  # shellcheck disable=SC2329 # called by spl_doc_tree_check_exec
  spl_doc_tree_check_sql() { _check_sql_real | sed "$neuter"; }
  if out=$(check_planted); then fail "5. CONTROL $inv neutered and case 2 still passes: $out"
  else pass "5. CONTROL $inv neutered: case 2 fails ($(grep -o 'violations=[0-9]*' <<<"$out"))"; fi
done

(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1

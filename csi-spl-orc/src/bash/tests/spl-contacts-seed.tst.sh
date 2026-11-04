#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_contacts_seed (SPL-4635, spec 154) adds a CSV file's rows to
#          ONE named person's contacts. Part A stubs the cloud
#          (spl_via_proxy records its call); part B runs the SQL against a
#          REAL throwaway Postgres with the real rdb migrations, as the NON-owner
#          runtime login so row-level security binds (SKIP when no docker /
#          psql / cached postgres image). Every row here is made up.
#   A1. ENV must be dev or prd; CONTACTS_PERSON must be HUM-<n>; the file
#       must exist; each refused before any DB call
#   A2. DRY_RUN defaults to 1 (a READ ONLY transaction); DRY_RUN=0 commits
#   A3. CONTROL: a row of another person than CONTACTS_PERSON refuses the
#       whole file before any DB call, naming the row, never the value
#   A4. CONTROL: a row with no name refuses the whole file the same way
#   A5. a bad email, a bad phone, a wrong header: refused, no DB call
#   B1. dry run: 3 rows would be added, nothing is written
#   B2. the run adds the 3 rows to that person only, prints 3 contact ids and
#       no value; another person's list is untouched
#   B3. CONTROL: the second run adds nothing twice (already 3, added 0); a
#       new row in the same file is the only one added
#   B4. a person with no humans row: refused by the FK, SQLSTATE only, the
#       transaction rolled back
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="${SEED_FUNC:-$PROJ_ROOT/src/bash/run/spl-contacts-seed.func.sh}"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT

HDR='person_id,first_name,last_name,email,phone'
# csvf <name> <row>...: a CSV file under $T with the header
csvf() { local f="$T/$1"; shift; { echo "$HDR"; printf '%s\n' "$@"; } >"$f"; echo "$f"; }
GOOD="$(csvf good.csv 'HUM-1,Alfa,Testone,alfa@example.com,' 'HUM-1,Bravo,Testtwo,BRAVO@example.com,+358 40 000 0000' \
  'HUM-1,Charlie,,,' 'HUM-1,Alfa,Testone,alfa@example.com,')"
# no output may carry a made-up value
leaks() { grep -lE 'Alfa|Bravo|Charlie|Delta|example\.com|358' "$@" 2>/dev/null; }

# A ---------------------------------------------------------------------------
# runa [VAR=val ...]: the action with the cloud stubbed
runa() {
  : >"$T/calls"
  env -u DRY_RUN -u CONTACTS_PERSON -u CONTACTS_FILE FUNC="$FUNC" T="$T" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF="$T/cnf.yaml"; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.org; }
    do_gcp_require_live_account() { return 0; }
    source "$FUNC"
    spl_via_proxy() { echo "proxy person=$CONTACTS_PERSON $1" >>"$T/calls"; head -n 2 "$2" | tail -n 1 >>"$T/calls"
      printf "rows 3\nalready 0\nwould_add 3\nadded 00000000-0000-0000-0000-000000000001\nlive 3\n" >"$3"; }
    do_spl_contacts_seed' >"$T/o" 2>"$T/e"
}
nocall() { [[ ! -s "$T/calls" ]]; }

runa ENV=lde CONTACTS_PERSON=HUM-1 CONTACTS_FILE="$GOOD"; rc=$?
[[ $rc -ne 0 ]] && nocall && pass "A1. ENV=lde refused before any DB call" || fail "A1. env rc=$rc $(cat "$T/calls")"
for p in '' HUM- hum-1 'HUM-1 OR 1=1' operator; do
  runa ENV=dev CONTACTS_PERSON="$p" CONTACTS_FILE="$GOOD"; rc=$?
  [[ $rc -ne 0 ]] && nocall && grep -q 'CONTACTS_PERSON must be a person id' "$T/e" &&
    pass "A1. CONTACTS_PERSON '$p' refused, no DB call" || fail "A1. person '$p' rc=$rc $(cat "$T/calls" "$T/e")"
done
runa ENV=dev CONTACTS_PERSON=HUM-1 CONTACTS_FILE="$T/none.csv"; rc=$?
[[ $rc -ne 0 ]] && nocall && grep -q 'CONTACTS_FILE is not a readable file' "$T/e" &&
  pass "A1. a missing file refused, no DB call" || fail "A1. file rc=$rc $(cat "$T/e")"

runa ENV=dev CONTACTS_PERSON=HUM-1 CONTACTS_FILE="$GOOD"; rc=$?
[[ $rc -eq 0 ]] && grep -q '^proxy person=HUM-1 _spl_contacts_seed_run' "$T/calls" && grep -qx 'BEGIN READ ONLY;' "$T/calls" &&
  grep -q '"dry_run": true' "$T/o" && grep -q '"would_add": 3' "$T/o" && [[ -z "$(leaks "$T/o" "$T/e")" ]] &&
  pass "A2. DRY_RUN defaults to 1: a READ ONLY transaction, counts only" || fail "A2. rc=$rc $(cat "$T/calls" "$T/o" "$T/e")"
runa ENV=prd CONTACTS_PERSON=HUM-1 CONTACTS_FILE="$GOOD" DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'BEGIN;' "$T/calls" && grep -q '"env": "prd"' "$T/o" &&
  grep -q '"contact_ids": \["00000000-0000-0000-0000-000000000001"\]' "$T/o" &&
  pass "A2. DRY_RUN=0 is the committing path, ids printed" || fail "A2. commit rc=$rc $(cat "$T/calls" "$T/o" "$T/e")"

f="$(csvf other.csv 'HUM-1,Alfa,Testone,alfa@example.com,' 'HUM-2,Delta,Testfour,delta@example.com,')"
runa ENV=dev CONTACTS_PERSON=HUM-1 CONTACTS_FILE="$f" DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && nocall && grep -q 'row 2: person_id is not CONTACTS_PERSON' "$T/e" && [[ -z "$(leaks "$T/o" "$T/e")" ]] &&
  pass "A3. CONTROL: a row of another person refuses the whole file, no DB call, no value" ||
  fail "A3. rc=$rc $(cat "$T/calls" "$T/e")"

f="$(csvf noname.csv 'HUM-1,Alfa,Testone,alfa@example.com,' 'HUM-1,,,delta@example.com,+358 1')"
runa ENV=dev CONTACTS_PERSON=HUM-1 CONTACTS_FILE="$f" DRY_RUN=0; rc=$?
[[ $rc -ne 0 ]] && nocall && grep -q 'row 2: no name' "$T/e" && [[ -z "$(leaks "$T/o" "$T/e")" ]] &&
  pass "A4. CONTROL: a row with no name refuses the whole file, no DB call, no value" ||
  fail "A4. rc=$rc $(cat "$T/calls" "$T/e")"

for c in 'bademail|HUM-1,Delta,Testfour,delta.example.com,|row 1: email is not an address' \
         'badphone|HUM-1,Delta,Testfour,,358-abc|row 1: phone is not a phone number' \
         'fields|HUM-1,Delta|row 1: 2 fields, not 5'; do
  IFS='|' read -r name row want <<<"$c"
  f="$(csvf "$name.csv" "$row")"
  runa ENV=dev CONTACTS_PERSON=HUM-1 CONTACTS_FILE="$f" DRY_RUN=0; rc=$?
  [[ $rc -ne 0 ]] && nocall && grep -q "$want" "$T/e" && [[ -z "$(leaks "$T/e")" ]] &&
    pass "A5. $name refused, no DB call, no value" || fail "A5. $name rc=$rc $(cat "$T/e")"
done
printf 'name,email\nHUM-1,x\n' >"$T/hdr.csv"
runa ENV=dev CONTACTS_PERSON=HUM-1 CONTACTS_FILE="$T/hdr.csv"; rc=$?
[[ $rc -ne 0 ]] && nocall && grep -q 'the header is not' "$T/e" && pass "A5. a wrong header refused" || fail "A5. header rc=$rc $(cat "$T/e")"

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
PG_CTR="spl-contacts-seed-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool \
  -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
# shellcheck source=pg-throwaway.inc.sh
source "$TEST_DIR/pg-throwaway.inc.sh"
PGPORT="$(pg_throwaway_port "$PG_CTR")" || exit 1
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }
q() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" -c "$1"; }
q "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 "$OWNER_DSN" -v runtime_role=spool_rt \
  -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }
q "INSERT INTO humans (human_id) VALUES ('HUM-1'), ('HUM-2')" >/dev/null
q "INSERT INTO personal.contacts (person_id, first_name, email) VALUES ('HUM-2', 'Alfa', 'alfa@example.com')" >/dev/null
# list <person>: that person's live rows as the owner sees them, ordered
list() { q "SELECT coalesce(string_agg(first_name || '/' || coalesce(email, '-'), ',' ORDER BY first_name), '') FROM personal.contacts WHERE person_id = '$1' AND deleted_at IS NULL"; }
ids() { q "SELECT coalesce(string_agg(contact_id::text, ',' ORDER BY contact_id), '') FROM personal.contacts WHERE person_id = '$1'"; }

# runp <person> <file> <dry>: the action through the real DB as the runtime login
runp() {
  env -u DRY_RUN FUNC="$FUNC" T="$T" ENV=dev CONTACTS_PERSON="$1" CONTACTS_FILE="$2" DRY_RUN="$3" RT_DSN="$RT_DSN" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF="$T/cnf.yaml"; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.org; }
    do_gcp_require_live_account() { return 0; }
    source "$FUNC"
    spl_via_proxy() { SPL_PROXY_DSN="$RT_DSN" "$@"; }
    do_spl_contacts_seed' >"$T/o" 2>"$T/e"
}
js() { python3 -c 'import json,sys; d=json.loads(open(sys.argv[1]).readline()); print(d.get(sys.argv[2]))' "$T/o" "$1"; }

h2="$(list HUM-2)"
runp HUM-1 "$GOOD" 1; rc=$?
[[ $rc -eq 0 && "$(js rows)" == 3 && "$(js already)" == 0 && "$(js would_add)" == 3 && "$(js live)" == 0 && -z "$(list HUM-1)" ]] &&
  pass "B1. dry run: 3 rows would be added, nothing written" || fail "B1. rc=$rc $(cat "$T/o" "$T/e") / $(list HUM-1)"

runp HUM-1 "$GOOD" 0; rc=$?
want="Alfa/alfa@example.com,Bravo/bravo@example.com,Charlie/-"
got_ids="$(python3 -c 'import json,sys; print(",".join(sorted(json.loads(open(sys.argv[1]).readline())["contact_ids"])))' "$T/o" 2>/dev/null)"
[[ $rc -eq 0 && "$(js added)" == 3 && "$(js live)" == 3 && "$(list HUM-1)" == "$want" && "$got_ids" == "$(ids HUM-1)" &&
   "$(list HUM-2)" == "$h2" && -z "$(leaks "$T/o" "$T/e")" ]] &&
  pass "B2. added 3 to HUM-1 only, the 3 ids printed, no value; HUM-2 untouched" ||
  fail "B2. rc=$rc $(cat "$T/o" "$T/e") / $(list HUM-1) / $(list HUM-2)"

before="$(ids HUM-1)"
runp HUM-1 "$GOOD" 0; rc=$?
[[ $rc -eq 0 && "$(js already)" == 3 && "$(js added)" == 0 && "$(ids HUM-1)" == "$before" ]] &&
  pass "B3. CONTROL: the second run adds nothing twice (already 3, added 0)" || fail "B3. rc=$rc $(cat "$T/o" "$T/e")"
cp "$GOOD" "$T/more.csv"; echo 'HUM-1,Delta,Testfour,delta@example.com,' >>"$T/more.csv"
runp HUM-1 "$T/more.csv" 0; rc=$?
[[ $rc -eq 0 && "$(js already)" == 3 && "$(js added)" == 1 && "$(js live)" == 4 && "$(list HUM-2)" == "$h2" ]] &&
  pass "B3. a new row in the same file is the only one added" || fail "B3. more rc=$rc $(cat "$T/o" "$T/e")"

f="$(csvf ghost.csv 'HUM-9,Echo,Testfive,echo@example.com,')"
runp HUM-9 "$f" 0; rc=$?
[[ $rc -ne 0 && "$(q "SELECT count(*) FROM personal.contacts WHERE person_id = 'HUM-9'")" == 0 ]] &&
  grep -q 'ERROR: *23503' "$T/e" && [[ -z "$(leaks "$T/o" "$T/e")" ]] &&
  pass "B4. a person with no humans row: refused (23503), rolled back, no value" || fail "B4. rc=$rc $(cat "$T/o" "$T/e")"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }

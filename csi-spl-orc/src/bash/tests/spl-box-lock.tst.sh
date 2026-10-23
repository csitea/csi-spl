#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_box_lock (create, show) and do_spl_box_lock_break, spec 025
#          box-owner-lock.md row B6 (SPL-3014). Part A stubs spool, the cloud
#          and the proxy; part B runs the SQL against a REAL throwaway
#          Postgres with the real rdb migrations, as the NON-owner runtime
#          login so rdb 0213's row-level security binds (SKIP when no docker /
#          psql / cached postgres image). No real box, key or workspace:
#          fixture ids and generated keys only.
#   A1. BOX_LOCK_CMD other than create / show is refused
#   A2. create: spool lock create's statement is saved 0600 as
#       lock/lock.signed.json; the cnf entry names tenant, box and
#       lock_pubkey; owners, peers and hide-posts reach spool
#   A3. create refuses: bad owners, an unsealed box, an existing statement,
#       a statement with no box_signature (nothing saved)
#   A4. show: the cnf entry is read and handed to the DB read
#   A5. RED CONTROL break: the box still in the working cnf, or still on
#       origin/master's cnf, is refused before any DB call; removed from
#       both, the dry run reads; DRY_RUN=0 needs BOX_LOCK_GO
#   B1. show: "REFUSED" for a listed box with no row, "matches" with its row,
#       "NOT in cnf" for an unlisted row
#   B2. break dry run: counts the row, deletes nothing
#   B3. break: deletes the row, writes one lifted/break audit row; the other
#       box's row is untouched (CONTROL); a second break is refused and
#       writes nothing
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
LOCK="$PROJ_ROOT/src/bash/run/spl-box-lock.func.sh"
BREAK="$PROJ_ROOT/src/bash/run/spl-box-lock-break.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT

K1=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
K2=/////////////////////////////////////////w=

# a fake spool: status from $SPOOL_STATUS, create prints a fixture statement
# (box_signature dropped with SPOOL_NO_BOXSIG=1) and logs its argv
mkdir -p "$T/bin"
cat >"$T/bin/spool" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$T/spool.argv"
case "$1 $2" in
  "lock status") echo "${SPOOL_STATUS:-sealed}" ;;
  "lock create")
    body='{"tenant_id":"ws-a","box_id":"box-a","lock_pubkey":"'"$K1"'","box_pubkey":"'"$K2"'","owners":["HUM-1"],"peer_boxes":[],"hide_posts":true,"version":1}'
    if [[ -n "${SPOOL_NO_BOXSIG:-}" ]]; then
      jq -n --arg b "$body" '{signed_body: $b, signature: "c2ln"}'
    else
      jq -n --arg b "$body" '{signed_body: $b, signature: "c2ln", box_signature: "Ym94"}'
    fi ;;
  *) exit 2 ;;
esac
EOF
chmod +x "$T/bin/spool"

# runa <func> [VAR=val ...]: an action with the cloud stubbed; the proxy logs
# its call and the env it saw
runa() {
  local fn="$1"; shift
  : >"$T/calls"
  env -u DRY_RUN -u BOX_LOCK_GO -u BOX_LOCK_CMD -u BOX_LOCK_OWNERS -u BOX_LOCK_PEER_BOXES -u BOX_LOCK_HIDE_POSTS \
    LOCK="$LOCK" BREAK="$BREAK" T="$T" K1="$K1" K2="$K2" SPOOL_BIN="$T/bin/spool" SPOOL_KEYS_DIR="$T/keys" \
    BOX_LOCK_REPO="$T/repo" PROJ_PATH="$PROJ_ROOT" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF="$T/cnf.yaml"; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
    do_gcp_require_live_account() { return 0; }
    source "$LOCK"; source "$BREAK"
    spl_via_proxy() { echo "proxy $* want=${BOX_LOCK_WANT:-} dry=${BOX_LOCK_DRY:-}" >>"$T/calls"; }
    '"$fn" >"$T/o" 2>"$T/e"
}

# cnf <file> <entries yaml>: a cnf with hub.box_locks_expected = entries
cnf() { printf 'env:\n  hub:\n    box_locks_expected: %s\n' "$2" >"$1"; }
LISTED="[{tenant: ws-a, box: box-a, lock_pubkey: $K1}]"

# A1 ---------------------------------------------------------------------------
runa do_spl_box_lock BOX_LOCK_CMD=lift; rc=$?
[[ $rc -ne 0 ]] && grep -q 'BOX_LOCK_CMD must be create or show' "$T/e" &&
  pass "A1. BOX_LOCK_CMD=lift refused" || fail "A1. rc=$rc $(cat "$T/e")"

# A2 ---------------------------------------------------------------------------
runa do_spl_box_lock BOX_LOCK_CMD=create BOX_LOCK_OWNERS=HUM-1,HUM-2 BOX_LOCK_PEER_BOXES=box-p BOX_LOCK_HIDE_POSTS=false; rc=$?
signed="$T/keys/lock/lock.signed.json"
[[ $rc -eq 0 && -f "$signed" && "$(stat -c %a "$signed")" == 600 ]] && jq -e '.box_signature == "Ym94"' "$signed" >/dev/null &&
  pass "A2. create saved the signed statement 0600 as lock/lock.signed.json" || fail "A2. rc=$rc $(cat "$T/e")"
grep -q '^  - tenant: ws-a$' "$T/o" && grep -q '^    box: box-a$' "$T/o" && grep -qF "    lock_pubkey: $K1" "$T/o" &&
  pass "A2. create prints the hub.box_locks_expected entry" || fail "A2. cnf entry: $(cat "$T/o")"
grep -qx 'lock create --owners HUM-1,HUM-2 --peer-boxes box-p --hide-posts=false' "$T/spool.argv" &&
  pass "A2. owners, peers and hide-posts reach spool lock create" || fail "A2. argv: $(cat "$T/spool.argv")"

# A3 ---------------------------------------------------------------------------
runa do_spl_box_lock BOX_LOCK_CMD=create BOX_LOCK_OWNERS=HUM-1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'is locked already' "$T/e" &&
  pass "A3. an existing statement is never overwritten" || fail "A3. existing rc=$rc $(cat "$T/e")"
rm -rf "$T/keys"
runa do_spl_box_lock BOX_LOCK_CMD=create BOX_LOCK_OWNERS=admin; rc=$?
[[ $rc -ne 0 ]] && grep -q 'HUM-\* ids' "$T/e" && pass "A3. owners that are not HUM-* refused" || fail "A3. owners rc=$rc"
runa do_spl_box_lock BOX_LOCK_CMD=create BOX_LOCK_OWNERS=HUM-1 SPOOL_STATUS=not-sealed; rc=$?
[[ $rc -ne 0 ]] && grep -q 'seal it first' "$T/e" && pass "A3. an unsealed box refused" || fail "A3. unsealed rc=$rc $(cat "$T/e")"
runa do_spl_box_lock BOX_LOCK_CMD=create BOX_LOCK_OWNERS=HUM-1 SPOOL_NO_BOXSIG=1; rc=$?
[[ $rc -ne 0 && ! -e "$signed" ]] && grep -q 'no signed version 1 lock' "$T/e" &&
  pass "A3. a statement without box_signature refused, nothing saved" || fail "A3. no boxsig rc=$rc $(cat "$T/e")"

# A4 ---------------------------------------------------------------------------
cnf "$T/cnf.yaml" "$LISTED"
runa do_spl_box_lock ENV=dev BOX_LOCK_CMD=show BOX_LOCK_TENANT=ws-a BOX_LOCK_BOX=box-a; rc=$?
[[ $rc -eq 0 ]] && grep -qF "cnf: listed lock_pubkey=$K1" "$T/o" && grep -qF "proxy _spl_box_lock_show_run ws-a box-a want=$K1" "$T/calls" &&
  pass "A4. show reads the cnf entry and hands it to the DB read" || fail "A4. rc=$rc $(cat "$T/o" "$T/e" "$T/calls")"
runa do_spl_box_lock ENV=dev BOX_LOCK_CMD=show BOX_LOCK_TENANT="ws-a';--" BOX_LOCK_BOX=box-a; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "A4. a tenant that is not an id is refused before the DB" || fail "A4. bad id rc=$rc"

# A5 ---------------------------------------------------------------------------
# the trunk: a bare origin whose master's dev cnf lists box-a
git init -q --bare "$T/origin.git"
git init -q "$T/seed" && mkdir -p "$T/seed/csi-spl-cnf/csi-spl"
cnf "$T/seed/csi-spl-cnf/csi-spl/dev.env.yaml" "$LISTED"
git -C "$T/seed" add -A && git -C "$T/seed" -c user.name=t -c user.email=t@example.com commit -qm listed &&
  git -C "$T/seed" push -q "$T/origin.git" HEAD:master
git clone -q "$T/origin.git" "$T/repo" 2>/dev/null

runa do_spl_box_lock_break ENV=dev BOX_LOCK_TENANT=ws-a BOX_LOCK_BOX=box-a; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'in hub.box_locks_expected of the dev cnf' "$T/e" &&
  pass "A5. RED CONTROL: break refused while the working cnf lists the box, no DB call" || fail "A5. working rc=$rc $(cat "$T/e" "$T/calls")"
cnf "$T/cnf.yaml" "[]"
runa do_spl_box_lock_break ENV=dev BOX_LOCK_TENANT=ws-a BOX_LOCK_BOX=box-a; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q 'still in hub.box_locks_expected on origin/master' "$T/e" &&
  pass "A5. RED CONTROL: break refused while origin/master's cnf lists the box, no DB call" || fail "A5. trunk rc=$rc $(cat "$T/e" "$T/calls")"
cnf "$T/seed/csi-spl-cnf/csi-spl/dev.env.yaml" "[]"
git -C "$T/seed" -c user.name=t -c user.email=t@example.com commit -qam removed && git -C "$T/seed" push -q "$T/origin.git" HEAD:master
runa do_spl_box_lock_break ENV=dev BOX_LOCK_TENANT=ws-a BOX_LOCK_BOX=box-a; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'proxy _spl_box_lock_break_run ws-a box-a want= dry=1' "$T/calls" &&
  pass "A5. removed on trunk (fetched): the dry run reads" || fail "A5. dry rc=$rc $(cat "$T/e" "$T/calls")"
runa do_spl_box_lock_break ENV=dev BOX_LOCK_TENANT=ws-a BOX_LOCK_BOX=box-a DRY_RUN=0; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q "owner's go" "$T/e" &&
  pass "A5. DRY_RUN=0 without BOX_LOCK_GO refused" || fail "A5. no go rc=$rc $(cat "$T/e")"
runa do_spl_box_lock_break ENV=dev BOX_LOCK_TENANT=ws-a BOX_LOCK_BOX=box-a DRY_RUN=0 BOX_LOCK_GO=0d052d67; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'proxy _spl_box_lock_break_run ws-a box-a want= dry=0' "$T/calls" && grep -q 'DM note (8.3) is not built' "$T/e" &&
  pass "A5. with the go: the delete path, and it says the DM note is not built" || fail "A5. go rc=$rc $(cat "$T/e" "$T/calls")"

# B ----------------------------------------------------------------------------
PG_IMAGE="${SPOOL_TEST_PG_IMAGE:-postgres:16-alpine}"
if ! command -v docker >/dev/null || ! command -v psql >/dev/null || ! docker image inspect "$PG_IMAGE" >/dev/null 2>&1; then
  echo "SKIP: part B, no docker / psql / cached $PG_IMAGE image"
  (( fails == 0 )) && { echo "ALL PASS"; exit 0; }; echo "$fails FAILED"; exit 1
fi
export GOFLAGS=-mod=mod GOPROXY=off GOSUMDB=off GOTOOLCHAIN=local
# shellcheck source=../../../../csi-spl-api/src/bash/use-go-toolchain.sh
source "$APP_ROOT/csi-spl-api/src/bash/use-go-toolchain.sh"
spl_export_go_path || { echo "FAIL: no go toolchain"; exit 1; }
BIN="$T/spool-real"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-box-lock-pg-$$"
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
q "INSERT INTO tenants (tenant_id, root_pubkey) VALUES ('ws-a', decode(repeat('ab', 32), 'hex'))" >/dev/null
lockrow() {
  q "INSERT INTO box_locks (tenant_id, box_id, lock_pubkey, box_pubkey, owners, version, signed_body, signature)
     VALUES ('ws-a', '$1', '$K1', '$K2', '{HUM-1}', 1, '{}', 'c2ln')" >/dev/null
}

# runb <fn> <tenant> <box> [VAR=val ...]: a run helper against the runtime login
runb() {
  local fn="$1" t="$2" b="$3"; shift 3
  env LOCK="$LOCK" BREAK="$BREAK" SPL_PROXY_DSN="$RT_DSN" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${LOCK%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$LOCK"; source "$BREAK"
    '"$fn"' "$0" "$1"' "$t" "$b" >"$T/o" 2>"$T/e"
}

runb _spl_box_lock_show_run ws-a box-a BOX_LOCK_WANT="$K1"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'verdict: REFUSED by the hub: cnf lists the box, no lock row' "$T/o" &&
  pass "B1. show: a listed box with no row reads REFUSED" || fail "B1. no row rc=$rc $(cat "$T/o" "$T/e")"
lockrow box-a; lockrow box-b
runb _spl_box_lock_show_run ws-a box-a BOX_LOCK_WANT="$K1"; rc=$?
[[ $rc -eq 0 ]] && grep -q 'verdict: locked, matches cnf' "$T/o" && grep -q 'HUM-1' "$T/o" &&
  pass "B1. show: the row under the listed key reads matches, with its owners" || fail "B1. row rc=$rc $(cat "$T/o" "$T/e")"
runb _spl_box_lock_show_run ws-a box-b BOX_LOCK_WANT=""; rc=$?
[[ $rc -eq 0 ]] && grep -q 'verdict: locked, NOT in cnf' "$T/o" &&
  pass "B1. show: an unlisted row reads NOT in cnf" || fail "B1. unlisted rc=$rc $(cat "$T/o" "$T/e")"

runb _spl_box_lock_break_run ws-a box-a BOX_LOCK_DRY=1; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'dry_run: would delete 1 box_locks row(s)' "$T/o" && [[ "$(q "SELECT count(*) FROM box_locks")" == 2 ]] &&
  pass "B2. break dry run: counts 1, deletes nothing" || fail "B2. rc=$rc $(cat "$T/o" "$T/e")"

runb _spl_box_lock_break_run ws-a box-a BOX_LOCK_DRY=0; rc=$?
[[ $rc -eq 0 ]] && grep -q 'broke: deleted 1' "$T/o" &&
  [[ "$(q "SELECT count(*) FROM box_locks WHERE box_id = 'box-a'")" == 0 ]] &&
  [[ "$(q "SELECT count(*) FROM box_lock_audit WHERE box_id = 'box-a' AND path = 'break' AND verdict = 'lifted'")" == 1 ]] &&
  pass "B3. break deletes the row and writes one lifted/break audit row" || fail "B3. rc=$rc $(cat "$T/o" "$T/e")"
[[ "$(q "SELECT count(*) FROM box_locks WHERE box_id = 'box-b'")" == 1 ]] &&
  pass "B3. CONTROL: the other box's row is untouched" || fail "B3. box-b row gone"
runb _spl_box_lock_break_run ws-a box-a BOX_LOCK_DRY=0; rc=$?
[[ $rc -ne 0 ]] && grep -q 'nothing to break' "$T/e" &&
  [[ "$(q "SELECT count(*) FROM box_lock_audit WHERE box_id = 'box-a' AND path = 'break'")" == 1 ]] &&
  pass "B3. a second break is refused and writes nothing" || fail "B3. second rc=$rc $(cat "$T/o" "$T/e")"

(( fails == 0 )) && { echo "ALL PASS"; exit 0; }
echo "$fails FAILED"; exit 1

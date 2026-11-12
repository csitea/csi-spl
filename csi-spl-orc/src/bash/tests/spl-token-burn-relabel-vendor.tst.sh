#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_token_burn_relabel_vendor (SPL-5370, spec 140) re-labels
#          unpriced fleet_token_burn_events minutes stored under the wrong
#          vendor (e.g. vendor=claude for model=gemini-3.8-flash), in one
#          operator transaction, and re-rolls affected fleet_token_burn_daily
#          days. Part A stubs cloud + psql; Part B runs against a throwaway
#          Postgres with real rdb migrations and non-owner runtime RLS grants.
#   A1. required vars (MODEL, FROM_VENDOR, TO_VENDOR, FROM) have no default;
#       DRY_RUN=0 without TOKEN_RELABEL_EXPECT, bad vendor, same vendor, bad
#       model/from/box/expect/DRY_RUN are refused before any DB or proxy call
#   A2. DRY_RUN defaults to 1 (READ ONLY + ROLLBACK); DSN reaches psql via
#       PGPASSWORD/env, never on argv or in logs
#   B1. DRY_RUN=1 prints matched=4 and DRY_ROW before/after agent+vendor lines,
#       writes nothing
#   B2. TOKEN_RELABEL_EXPECT mismatch refuses DRY_RUN=0 and rolls back
#   B3. DRY_RUN=0 relabels unpriced matching rows, qualifies non-native
#       agent_ids as "<id> (<to_vendor>)" while keeping native ids ("a-402"),
#       splits daily rows cleanly from later same-day claude minutes, removes
#       orphaned daily rows, and leaves all 7 control rows untouched
#   B4. a re-run with TOKEN_RELABEL_EXPECT=0 matches 0 rows (idempotent)
#   B5. CONTROLS: stripping `NOT priced` alone overwrites priced cost=0 row;
#       stripping `cost_micros = 0` alone overwrites unpriced cost>0 row
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-token-burn-relabel-vendor.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT

# A ---------------------------------------------------------------------------
mkdir -p "$T/bin"
cat >"$T/bin/psql" <<'SH'
#!/usr/bin/env bash
echo "argv $*" >>"$STUB_CALLS"
echo "pgpass=${PGPASSWORD:-<none>} pghost=${PGHOST:-<none>}" >>"$STUB_CALLS"
for ((i=1; i<=$#; i++)); do
  if [[ "${!i}" == "-f" ]]; then j=$((i+1)); cat "${!j}" >>"$STUB_SQL"; fi
done
echo "PLAN matched=2 from_vendor=claude to_vendor=agy model=gemini-3.8-flash from=2026-11-01 box=bx"
echo -e "DRY_ROW\t10\tbx\tc-1\t2026-11-06T09:04:00Z\tclaude->agy\tgemini-3.8-flash\tin=10 out=2 cr=3 cw=0 priced=f"
echo "SUMMARY updated=2 rolled_days=1"
SH
chmod +x "$T/bin/psql"

runa() {
  : >"$T/calls"; : >"$T/sql"
  env -u DRY_RUN -u TOKEN_RELABEL_MODEL -u TOKEN_RELABEL_FROM_VENDOR -u TOKEN_RELABEL_TO_VENDOR     -u TOKEN_RELABEL_FROM -u TOKEN_RELABEL_BOX -u TOKEN_RELABEL_EXPECT     FUNC="$FUNC" T="$T" PATH="$T/bin:$PATH" STUB_CALLS="$T/calls" STUB_SQL="$T/sql" ENV=prd "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF=/dev/null; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
    do_gcp_require_live_account() { return 0; }
    spl_via_proxy() { echo "proxy $*" >>"$T/calls"; SPL_PROXY_DSN="postgres://u:s3cret@127.0.0.1:1/db" "$@"; }
    source "$FUNC"
    do_spl_token_burn_relabel_vendor' >"$T/o" 2>"$T/e"
}

ok=(TOKEN_RELABEL_MODEL=gemini-3.8-flash TOKEN_RELABEL_FROM_VENDOR=claude TOKEN_RELABEL_TO_VENDOR=agy TOKEN_RELABEL_FROM=2026-11-01)
for bad in "TOKEN_RELABEL_MODEL=" "TOKEN_RELABEL_FROM_VENDOR=" "TOKEN_RELABEL_TO_VENDOR=" "TOKEN_RELABEL_FROM=" \
           "TOKEN_RELABEL_FROM_VENDOR=openai" "TOKEN_RELABEL_TO_VENDOR=google" \
           "TOKEN_RELABEL_TO_VENDOR=claude" "TOKEN_RELABEL_MODEL=m'1" "TOKEN_RELABEL_MODEL=m 1" \
           "TOKEN_RELABEL_FROM=01.11.2026" "TOKEN_RELABEL_FROM=2026-11-01T00:00:00+02:00" \
           "TOKEN_RELABEL_BOX=bad.box!" "TOKEN_RELABEL_EXPECT=-1" "TOKEN_RELABEL_EXPECT=abc" "DRY_RUN=2" "DRY_RUN=0"; do
  runa "${ok[@]}" "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "A1. $bad refused before any DB call" || fail "A1. $bad: rc=$rc $(cat "$T/calls" "$T/e")"
done
runa "${ok[@]}" DRY_RUN=0 TOKEN_RELABEL_EXPECT=""; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "A1. DRY_RUN=0 with empty TOKEN_RELABEL_EXPECT refused before any DB call" ||
  fail "A1. empty expect: rc=$rc $(cat "$T/calls" "$T/e")"

runa "${ok[@]}" TOKEN_RELABEL_BOX=bx; rc=$?
[[ $rc -eq 0 ]] && grep -q 'BEGIN TRANSACTION READ ONLY;' "$T/sql" && grep -q 'DRY_RUN prd: matched=2' "$T/e" &&
  pass "A2. DRY_RUN defaults to 1 (READ ONLY transaction, rolled back)" || fail "A2. dry: rc=$rc $(cat "$T/e")"
grep -q '^pgpass=s3cret pghost=127.0.0.1$' "$T/calls" && ! grep '^argv' "$T/calls" | grep s3cret >/dev/null &&
  ! grep -q s3cret "$T/e" "$T/o" &&
  pass "A2. DSN secret is passed via environment, never argv or logs" || fail "A2. dsn: $(cat "$T/calls" "$T/e")"

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
BIN="$T/spool-real"
(cd "$APP_ROOT/csi-spl-api/src/go/spool-hub-api" && go build -o "$BIN" ./cmd/spool) || { fail "spool build"; exit 1; }
PG_CTR="spl-token-relabel-pg-$$"
docker run -d --rm --pull never --name "$PG_CTR" -e POSTGRES_USER=spool -e POSTGRES_PASSWORD=spool   -e POSTGRES_DB=spool_hub -p 127.0.0.1::5432 "$PG_IMAGE" >/dev/null
# shellcheck source=pg-throwaway.inc.sh
source "$TEST_DIR/pg-throwaway.inc.sh"
PGPORT="$(pg_throwaway_port "$PG_CTR")" || exit 1
for _ in $(seq 1 60); do docker exec "$PG_CTR" pg_isready -U spool -d spool_hub -h 127.0.0.1 >/dev/null 2>&1 && break; sleep 0.5; done
OWNER_DSN="postgres://spool:spool@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
RT_DSN="postgres://spool_rt:rt@127.0.0.1:$PGPORT/spool_hub?sslmode=disable"
"$BIN" migrate --db "$OWNER_DSN" --sql-dir "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub" >/dev/null || { fail "migrate"; exit 1; }
q() { PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 -At "$OWNER_DSN" -c "$1"; }
q "CREATE ROLE spool_rt LOGIN NOCREATEDB NOCREATEROLE PASSWORD 'rt'" >/dev/null
PGPASSWORD=spool psql -X -q -v ON_ERROR_STOP=1 "$OWNER_DSN" -v runtime_role=spool_rt   -f "$APP_ROOT/csi-spl-rdb/src/sql/postgres/spool-hub-roles/runtime-grants.sql" >/dev/null || { fail "grants"; exit 1; }

row() {
  q "INSERT INTO fleet_token_burn_events (box_tag, agent_id, vendor, model, minute_bucket, tokens_in, tokens_out,
     cache_read, cache_write, cost_micros, currency, priced, is_metered)
     VALUES ('$1', '$2', '$3', '$4', '$5', $6, $7, $8, $9, ${10}, 'USD', ${11}, true)" >/dev/null
}
# 4 target rows on box bx:
row bx c-1 claude gemini-3.8-flash 2026-11-06T09:04:00Z 7600 2510 480763 6202 0 false
row bx unattributed claude gemini-3.8-flash 2026-11-06T09:08:00Z 15010 597 39740 0 0 false
row bx c-9 claude gemini-3.8-flash 2026-11-06T11:00:00Z 500 50 100 0 0 false
row bx a-402 claude gemini-3.8-flash 2026-11-06T11:05:00Z 400 40 80 0 0 false
# 7 control rows (must not change):
row bx c-1 claude claude-opus-5-5 2026-11-06T20:00:00Z 200 40 0 5 123 true
row bx unattributed claude claude-opus-5-5 2026-11-06T09:09:00Z 100 50 0 10 0 false
row bx a-401 agy gemini-3.8-flash 2026-11-06T23:26:00Z 14617 1305 699277 2673 0 false
row bx c-2 claude gemini-3.8-flash 2026-11-06T10:00:00Z 1000 100 0 0 0 true
row bx c-2b claude gemini-3.8-flash 2026-11-06T10:01:00Z 1000 100 0 0 999 false
row bx c-3 claude gemini-3.8-flash 2026-10-31T23:59:00Z 1000 100 0 0 0 false
row other c-4 claude gemini-3.8-flash 2026-11-06T10:00:00Z 1000 100 0 0 0 false
# Pre-existing daily rows: c-9 on 2026-11-06 (orphaned once c-9 -> c-9 (agy)),
# plus a pruned historical day (2025-12-01, 0 events) that must stay untouched.
q "INSERT INTO fleet_token_burn_daily (day_bucket, box_tag, agent_id, vendor, model, minutes,
   tokens_in, tokens_out, cache_read, cache_write, cost_micros, currency, is_metered)
   VALUES ('2026-11-06', 'bx', 'c-9', 'claude', 'gemini-3.8-flash', 1, 500, 50, 100, 0, 0, 'USD', true),
          ('2025-12-01', 'bx', 'c-old', 'claude', 'claude-opus-5-5', 3, 900, 90, 0, 0, 500, 'USD', true)" >/dev/null

snap() { q "SELECT string_agg(box_tag || ':' || agent_id || '@' || to_char(minute_bucket AT TIME ZONE 'UTC','YYYY-MM-DD HH24:MI') || '=' || vendor || '/' || priced, ',' ORDER BY id) FROM fleet_token_burn_events"; }

runp() {
  local fn="${1:-$FUNC}"; shift
  env -u DRY_RUN -u TOKEN_RELABEL_EXPECT -u TOKEN_RELABEL_BOX \
    FUNC="$fn" SPL_PROXY_DSN="$RT_DSN" ENV=dev "${ok[@]}" TOKEN_RELABEL_BOX=bx "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF=/dev/null; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
    do_gcp_require_live_account() { return 0; }
    spl_via_proxy() { "$@"; }
    source "$FUNC"
    do_spl_token_burn_relabel_vendor' >"$T/o" 2>&1
}

before="$(snap)"
runp "$FUNC" DRY_RUN=1; rc=$?
[[ $rc -eq 0 && "$(snap)" == "$before" ]] &&
  grep -q 'OK DRY_RUN dev: matched=4 ' "$T/o" &&
  grep -q $'DRY_ROW\t1\tbx\tc-1->c-1 (agy)\t2026-11-06T09:04:00Z\tclaude->agy\tgemini-3.8-flash' "$T/o" &&
  grep -q $'DRY_ROW\t4\tbx\ta-402->a-402\t2026-11-06T11:05:00Z\tclaude->agy\tgemini-3.8-flash' "$T/o" &&
  pass "B1. DRY_RUN=1 prints matched=4 and before/after agent+vendor DRY_ROW lines, writes nothing" || fail "B1. rc=$rc $(cat "$T/o")"

runp "$FUNC" TOKEN_RELABEL_EXPECT=5 DRY_RUN=0; rc=$?
[[ $rc -ne 0 && "$(snap)" == "$before" ]] && grep -q 'REFUSED matched=4 expect=5' "$T/o" &&
  pass "B2. TOKEN_RELABEL_EXPECT mismatch refuses DRY_RUN=0 and rolls back" || fail "B2. rc=$rc $(cat "$T/o")"

runp "$FUNC" TOKEN_RELABEL_EXPECT=4 DRY_RUN=0; rc=$?
got_t="$(q "SELECT string_agg(id || ':' || agent_id || ':' || vendor, ',' ORDER BY id) FROM fleet_token_burn_events WHERE id IN (1, 2, 3, 4)")"
got_c="$(q "SELECT string_agg(id || ':' || agent_id || ':' || vendor, ',' ORDER BY id) FROM fleet_token_burn_events WHERE id IN (5, 6, 7, 8, 9, 10, 11)")"
days="$(q "SELECT string_agg(agent_id || '=' || vendor || ':' || minutes || ':' || tokens_in, ',' ORDER BY agent_id) FROM fleet_token_burn_daily WHERE day_bucket = '2026-11-06' AND box_tag = 'bx'")"
old_day="$(q "SELECT count(*) FROM fleet_token_burn_daily WHERE day_bucket = '2025-12-01' AND agent_id = 'c-old'")"
[[ $rc -eq 0 &&
   "$got_t" == "1:c-1 (agy):agy,2:unattributed (agy):agy,3:c-9 (agy):agy,4:a-402:agy" &&
   "$got_c" == "5:c-1:claude,6:unattributed:claude,7:a-401:agy,8:c-2:claude,9:c-2b:claude,10:c-3:claude,11:c-4:claude" &&
   "$days" == "a-401=agy:1:14617,a-402=agy:1:400,c-1=claude:1:200,c-1 (agy)=agy:1:7600,c-2=claude:1:1000,c-2b=claude:1:1000,c-9 (agy)=agy:1:500,unattributed=claude:1:100,unattributed (agy)=agy:1:15010" &&
   "$old_day" == "1" ]] &&
  grep -q 'OK dev committed: matched=4 .* updated=4 rolled_days=1' "$T/o" &&
  pass "B3. DRY_RUN=0 relabels+qualifies targets, splits daily vendor rows, removes orphaned c-9 daily row, keeps controls & historical days" ||
  fail "B3. rc=$rc t=$got_t c=$got_c days=$days old=$old_day $(cat "$T/o")"

after="$(snap)"
runp "$FUNC" TOKEN_RELABEL_EXPECT=0 DRY_RUN=0; rc=$?
[[ $rc -eq 0 && "$(snap)" == "$after" ]] && grep -q 'matched=0 .* updated=0 rolled_days=0' "$T/o" &&
  pass "B4. a re-run with TOKEN_RELABEL_EXPECT=0 matches 0 rows (idempotent)" || fail "B4. rc=$rc $(cat "$T/o")"

# B5a. RED CONTROL: strip ONLY `NOT priced` (keep `cost_micros = 0`) -> priced cost=0 row id=8 is overwritten, id=9 untouched
mkdir -p "$T/ctl/src/bash/run"; ln -s "$PROJ_ROOT/lib" "$T/ctl/lib"
python3 - "$FUNC" "$T/ctl/src/bash/run/spl-token-burn-relabel-vendor.func.sh" <<'PY_CTL_A'
import sys; s = open(sys.argv[1]).read()
old = "AND is_metered AND NOT priced AND cost_micros = 0"
assert old in s
open(sys.argv[2], "w").write(s.replace(old, "AND is_metered AND cost_micros = 0"))
PY_CTL_A
runp "$T/ctl/src/bash/run/spl-token-burn-relabel-vendor.func.sh" TOKEN_RELABEL_EXPECT=1 DRY_RUN=0
v8="$(q "SELECT vendor || ':' || agent_id FROM fleet_token_burn_events WHERE id = 8")"
v9="$(q "SELECT vendor FROM fleet_token_burn_events WHERE id = 9")"
[[ "$v8" == "agy:c-2 (agy)" && "$v9" == "claude" ]] &&
  pass "B5a. CONTROL: without NOT priced alone, priced cost=0 row id=8 is overwritten while cost>0 id=9 stays claude" ||
  fail "B5a. CONTROL: id=8=$v8 id=9=$v9 ($(cat "$T/o"))"

# B5b. RED CONTROL: strip ONLY `cost_micros = 0` (keep `NOT priced`) -> unpriced cost>0 row id=9 is overwritten
python3 - "$FUNC" "$T/ctl/src/bash/run/spl-token-burn-relabel-vendor.func.sh" <<'PY_CTL_B'
import sys; s = open(sys.argv[1]).read()
old = "AND is_metered AND NOT priced AND cost_micros = 0"
assert old in s
open(sys.argv[2], "w").write(s.replace(old, "AND is_metered AND NOT priced"))
PY_CTL_B
runp "$T/ctl/src/bash/run/spl-token-burn-relabel-vendor.func.sh" TOKEN_RELABEL_EXPECT=1 DRY_RUN=0
v9b="$(q "SELECT vendor || ':' || agent_id FROM fleet_token_burn_events WHERE id = 9")"
[[ "$v9b" == "agy:c-2b (agy)" ]] &&
  pass "B5b. CONTROL: without cost_micros = 0 alone, unpriced cost>0 row id=9 is overwritten" ||
  fail "B5b. CONTROL: id=9=$v9b ($(cat "$T/o"))"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }

#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_model_prices_sync (spec 121 T303, section 7) fills the
#          hub-wide model_prices (rdb 0171) from cnf env.model_prices; a price
#          change is a new row; re-running writes nothing new. Part A stubs
#          the cloud (spl_via_proxy records its call); part B runs the SQL
#          against a REAL throwaway Postgres with the real rdb migrations, as
#          the NON-owner runtime login so row-level security binds (SKIP when
#          no docker / psql / cached postgres image).
#   A1. ENV must be dev or prd
#   A2. DRY_RUN defaults to 1; DRY_RUN=0 is the write path; the real cnf
#       (all.env.yaml) passes the checks
#   A3. CONTROL: an absent block, a bad kind / price / currency / valid_from
#       and a duplicate row are each refused before any DB call
#   B1. dry run on an empty table: every cnf row is new, nothing written
#   B2. the sync writes them; re-running writes nothing new (dry and real)
#   B3. a price change with a later valid_from is one new row, the old row
#       stays; a later valid_from at the SAME price adds nothing
#   B4. CONTROL: a held valid_from at another price is refused and the run
#       commits nothing, not even its other new row
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-model-prices-sync.func.sh"
REAL_CNF="$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT

# cnf <file> <valid_from> <in> <out> [extra yaml lines]: one anthropic model
# with an in and an out price
cnf() {
  printf 'env:\n  model_prices:\n    - provider: anthropic\n      model: m-1\n      currency: USD\n      valid_from: "%s"\n      per_million:\n        llm_tokens_in: %s\n        llm_tokens_out: %s\n' \
    "$2" "$3" "$4" >"$1"
  [[ -n "${5:-}" ]] && printf '%s\n' "$5" >>"$1"
  return 0
}

# A ---------------------------------------------------------------------------
# runa <cnf> [VAR=val ...]: the action with the cloud stubbed
runa() {
  local f="$1"; shift
  : >"$T/calls"
  env -u DRY_RUN FUNC="$FUNC" T="$T" CNF="$f" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF="$CNF"; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
    do_gcp_require_live_account() { return 0; }
    source "$FUNC"
    spl_via_proxy() { printf "proxy dry=%s rows=%s %s\n" "$MP_DRY" "$(grep -c . <<<"$MP_ROWS")" "$*" >>"$T/calls"; echo 0 >"$2"; }
    do_spl_model_prices_sync' >"$T/o" 2>"$T/e"
}

cnf "$T/ok.yaml" 2026-10-01T00:00:00Z 4000000 20000000
runa "$T/ok.yaml" ENV=lde; rc=$?
[[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "A1. ENV=lde refused before any DB call" || fail "A1. rc=$rc $(cat "$T/calls")"

runa "$T/ok.yaml" ENV=dev; rc=$?
[[ $rc -eq 0 ]] && grep -q '^proxy dry=1 rows=2 _spl_model_prices_sync_run' "$T/calls" &&
  grep -q '"env":"dev","dry_run":true,"cnf":2,"new":0' "$T/o" &&
  pass "A2. DRY_RUN defaults to 1, two cnf rows" || fail "A2. rc=$rc $(cat "$T/calls" "$T/o" "$T/e")"
runa "$T/ok.yaml" ENV=prd DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q '^proxy dry=0 rows=2 ' "$T/calls" && grep -q '"env":"prd","dry_run":false' "$T/o" &&
  pass "A2. DRY_RUN=0 is the write path" || fail "A2. write rc=$rc $(cat "$T/calls" "$T/o")"
runa "$REAL_CNF" ENV=dev; rc=$?
real_n="$(yq -r '.env.model_prices[].per_million | keys | .[]' "$REAL_CNF" | grep -c .)"
[[ $rc -eq 0 && "$real_n" -gt 0 ]] && grep -q "\"cnf\":$real_n," "$T/o" &&
  pass "A2. the real cnf passes: $real_n price rows" || fail "A2. real cnf rc=$rc n=$real_n $(cat "$T/o" "$T/e")"

printf 'env:\n  cost: {}\n' >"$T/bad-none.yaml"
cnf "$T/bad-kind.yaml" 2026-10-01T00:00:00Z 1 2 '        llm_tokens_thinking: 5'
cnf "$T/bad-price.yaml" 2026-10-01T00:00:00Z 1.5 2
cnf "$T/bad-neg.yaml" 2026-10-01T00:00:00Z -1 2
cnf "$T/bad-vf.yaml" 2026-10-01 1 2
sed 's/USD/usd/' "$T/ok.yaml" >"$T/bad-cur.yaml"
sed "s/model: m-1/model: \"m'1\"/" "$T/ok.yaml" >"$T/bad-model.yaml"
cnf "$T/bad-dup.yaml" 2026-10-01T00:00:00Z 1 2 "$(sed -n '3,$p' "$T/ok.yaml")"
for b in none:"holds no price" kind:"unknown kind" price:"not whole micros" neg:"not whole micros" \
         vf:"valid_from is not" cur:"bad currency" model:"bad model" dup:"twice"; do
  runa "$T/bad-${b%%:*}.yaml" ENV=dev DRY_RUN=0; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && grep -q "${b#*:}" "$T/e" &&
    pass "A3. CONTROL: bad ${b%%:*} refused, no DB call" || fail "A3. ${b%%:*} rc=$rc $(cat "$T/calls" "$T/e")"
done

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
PG_CTR="spl-model-prices-pg-$$"
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
rows() { q "SELECT coalesce(string_agg(kind || '@' || to_char(valid_from AT TIME ZONE 'UTC', 'MM-DD') || '=' || micros_per_million, ',' ORDER BY kind, valid_from), '') FROM model_prices"; }

# runp <cnf> <dry>: the sync SQL path, through the real DB as the runtime login
runp() {
  env FUNC="$FUNC" CNF="$1" MP_DRY="$2" SPL_PROXY_DSN="$RT_DSN" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    source "$FUNC"
    MP_ROWS="$(spl_model_prices_rows "$CNF")" || exit 1
    MP_ROWS="$MP_ROWS" _spl_model_prices_sync_run /dev/stdout' >"$T/o" 2>&1
}

v1="llm_tokens_in@10-01=4000000,llm_tokens_out@10-01=20000000"
runp "$T/ok.yaml" 1; rc=$?
[[ $rc -eq 0 && "$(tail -n 1 "$T/o")" == 2 && -z "$(rows)" ]] &&
  pass "B1. dry run: 2 rows new, nothing written" || fail "B1. rc=$rc $(cat "$T/o") / $(rows)"

runp "$T/ok.yaml" 0; rc=$?
[[ $rc -eq 0 && "$(tail -n 1 "$T/o")" == 2 && "$(rows)" == "$v1" ]] &&
  pass "B2. the sync wrote the 2 rows" || fail "B2. rc=$rc $(cat "$T/o") / $(rows)"
runp "$T/ok.yaml" 0; rc=$?
[[ $rc -eq 0 && "$(tail -n 1 "$T/o")" == 0 && "$(rows)" == "$v1" ]] &&
  pass "B2. re-running writes nothing new" || fail "B2. rerun rc=$rc $(cat "$T/o") / $(rows)"
runp "$T/ok.yaml" 1; rc=$?
[[ $rc -eq 0 && "$(tail -n 1 "$T/o")" == 0 ]] && pass "B2. a dry re-run counts 0 new" || fail "B2. dry rerun rc=$rc $(cat "$T/o")"

cnf "$T/v2.yaml" 2026-11-01T00:00:00Z 3000000 20000000
runp "$T/v2.yaml" 0; rc=$?
v2="llm_tokens_in@10-01=4000000,llm_tokens_in@11-01=3000000,llm_tokens_out@10-01=20000000"
[[ $rc -eq 0 && "$(tail -n 1 "$T/o")" == 1 && "$(rows)" == "$v2" ]] &&
  pass "B3. a price change is ONE new row, the old row stays, the unchanged out price adds none" ||
  fail "B3. rc=$rc $(cat "$T/o") / $(rows)"
in_force="$(q "SELECT micros_per_million FROM model_prices WHERE kind = 'llm_tokens_in' AND valid_from <= '2026-10-15' ORDER BY valid_from DESC LIMIT 1")"
[[ "$in_force" == 4000000 ]] && pass "B3. mid-October still prices at the old row" || fail "B3. in force $in_force"

# B4: the held 10-01 row at another price, plus a genuinely new kind
cnf "$T/clash.yaml" 2026-10-01T00:00:00Z 4500000 20000000 '        llm_tokens_cache_read: 400000'
runp "$T/clash.yaml" 0; rc=$?
[[ $rc -ne 0 && "$(rows)" == "$v2" ]] && grep -q 'a price change needs a new valid_from' "$T/o" &&
  grep -q 'anthropic/m-1/llm_tokens_in/' "$T/o" &&
  pass "B4. CONTROL: a held valid_from at another price is refused, nothing committed" ||
  fail "B4. rc=$rc $(cat "$T/o") / $(rows)"
runp "$T/clash.yaml" 1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'a price change needs a new valid_from' "$T/o" &&
  pass "B4. CONTROL: the dry run refuses it too" || fail "B4. dry rc=$rc $(cat "$T/o")"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }

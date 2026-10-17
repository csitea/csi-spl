#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_token_burn_reprice (SPL-2405, spec 140 T010) prices, once,
#          the fleet token minutes stored unpriced before their model had a
#          price, with the hub's own pricer (`spool fleet-tokens-reprice`).
#          Part A stubs the cloud and the binary; part B runs the real binary
#          against a REAL throwaway Postgres with the real rdb migrations, as
#          the NON-owner runtime login so row-level security binds (SKIP when
#          no docker / psql / cached postgres image).
#   A1. TOKEN_REPRICE_MODELS and TOKEN_REPRICE_FROM are required (no
#       default); a bad, empty or repeated model, a bad from, a bad DRY_RUN
#       are each refused before any DB call
#   A2. DRY_RUN defaults to 1 (no --write); DRY_RUN=0 passes --write; the DSN
#       reaches the binary in its environment, never its argv
#   A3. a binary without the verb is refused before any DB call
#   B1. DRY_RUN=1 prints what it would price, writes nothing
#   B2. DRY_RUN=0 prices the unpriced minutes of the named models at the
#       cost the live pricer gives (dated id at its base model), re-rolls
#       the day; CONTROL: a priced row, another model's and a row before
#       from are untouched
#   B3. a re-run prices 0 rows
#   B4. CONTROL: a named model with no price fails DRY_RUN=0 and keeps it unpriced
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/spl-token-burn-reprice.func.sh"
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
T=$(mktemp -d)
cleanup() { [[ -n "${PG_CTR:-}" ]] && docker rm -fv "$PG_CTR" >/dev/null 2>&1; rm -rf "$T"; }
trap cleanup EXIT

# A ---------------------------------------------------------------------------
# A stub spool: `help` lists the verb (unless STUB_NO_VERB), the verb records
# its argv and whether the DSN env reached it, and answers one clean model.
cat >"$T/spool" <<'SH'
#!/usr/bin/env bash
if [[ "$1" == help ]]; then [[ -n "${STUB_NO_VERB:-}" ]] || echo "  fleet-tokens-reprice  price ..."; exit 0; fi
echo "argv $*" >>"$STUB_CALLS"
echo "env_dsn=${SPOOL_HUB_DB_DSN:-<none>}" >>"$STUB_CALLS"
echo '{"dry_run":true,"from":"2026-10-16T00:00:00Z","models":[{"model":"m-1","unpriced_before":2,"priced":2,"cost_micros":"1500.000000","currency":"USD","unpriced_after":0}],"rolled_days":1}'
SH
chmod +x "$T/spool"

# runa [VAR=val ...]: the action with the cloud stubbed
runa() {
  : >"$T/calls"
  env -u DRY_RUN -u TOKEN_REPRICE_MODELS -u TOKEN_REPRICE_FROM FUNC="$FUNC" T="$T" STUB_CALLS="$T/calls" \
    TOKEN_REPRICE_SPOOL="$T/spool" ENV=prd "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "${FUNC%/src/bash/run/*}/lib/bash/funcs/spl-cloud-cnf.func.sh"
    do_require_bin() { return 0; }
    do_spl_cloud_cnf() { SPL_CNF=/dev/null; }
    do_gcp_pin_account() { GCP_ACCOUNT=sa@example.com; }
    do_gcp_require_live_account() { return 0; }
    spl_via_proxy() { echo "proxy $*" >>"$T/calls"; SPL_PROXY_DSN="postgres://u:s3cret@127.0.0.1:1/db" "$@"; }
    source "$FUNC"
    do_spl_token_burn_reprice' >"$T/o" 2>"$T/e"
}

ok=(TOKEN_REPRICE_MODELS=m-1 TOKEN_REPRICE_FROM=2026-10-16)
for bad in "TOKEN_REPRICE_MODELS=" "TOKEN_REPRICE_FROM=" "TOKEN_REPRICE_MODELS=m-1,,m-2" "TOKEN_REPRICE_MODELS=m-1," \
           "TOKEN_REPRICE_MODELS=m-1,m-1" "TOKEN_REPRICE_MODELS=m'1" "TOKEN_REPRICE_MODELS=m 1" \
           "TOKEN_REPRICE_FROM=16.10.2026" "TOKEN_REPRICE_FROM=2026-10-16T00:00:00+03:00" "DRY_RUN=2"; do
  runa "${ok[@]}" "$bad"; rc=$?
  [[ $rc -ne 0 && ! -s "$T/calls" ]] && pass "A1. $bad refused before any DB call" || fail "A1. $bad: rc=$rc $(cat "$T/calls" "$T/e")"
done
runa TOKEN_REPRICE_FROM=2026-10-16; rc=$?
[[ $rc -ne 0 ]] && grep -q 'TOKEN_REPRICE_MODELS is required (no default)' "$T/e" &&
  pass "A1. no TOKEN_REPRICE_MODELS default" || fail "A1. models default: rc=$rc $(cat "$T/e")"
runa TOKEN_REPRICE_MODELS=m-1; rc=$?
[[ $rc -ne 0 ]] && grep -q 'TOKEN_REPRICE_FROM is required (no default)' "$T/e" &&
  pass "A1. no TOKEN_REPRICE_FROM default" || fail "A1. from default: rc=$rc $(cat "$T/e")"

runa "${ok[@]}" TOKEN_REPRICE_MODELS='claude-haiku-4-5-20251001,mistral-large,claude-opus-5-5[1m]'; rc=$?
[[ $rc -eq 0 ]] && grep -q '^argv fleet-tokens-reprice --models claude-haiku-4-5-20251001,mistral-large,claude-opus-5-5\[1m\] --from 2026-10-16$' "$T/calls" &&
  grep -q 'DRY_RUN prd' "$T/e" && grep -q 'm-1 unpriced_before=2 would_price=2 cost_usd=0.0015 unpriced_after=0' "$T/e" &&
  pass "A2. DRY_RUN defaults to 1: no --write; real model names pass" || fail "A2. dry: rc=$rc $(cat "$T/calls" "$T/e")"
runa "${ok[@]}" TOKEN_REPRICE_FROM=2026-10-16T09:19:00Z DRY_RUN=0; rc=$?
[[ $rc -eq 0 ]] && grep -q '^argv fleet-tokens-reprice --models m-1 --from 2026-10-16T09:19:00Z --write$' "$T/calls" &&
  grep -q 'committed: 0 unpriced minutes left' "$T/e" &&
  pass "A2. DRY_RUN=0 passes --write" || fail "A2. write: rc=$rc $(cat "$T/calls" "$T/e")"
grep -q '^env_dsn=postgres://u:s3cret@127.0.0.1:1/db$' "$T/calls" && ! grep '^argv' "$T/calls" | grep s3cret >/dev/null &&
  ! grep -q s3cret "$T/e" "$T/o" &&
  pass "A2. the DSN is in the binary's environment, never its argv or the log" || fail "A2. dsn: $(cat "$T/calls" "$T/e")"
runa "${ok[@]}" STUB_NO_VERB=1; rc=$?
[[ $rc -ne 0 ]] && ! grep -q '^proxy' "$T/calls" && grep -q 'has no fleet-tokens-reprice verb' "$T/e" &&
  pass "A3. a binary without the verb is refused before any DB call" || fail "A3. rc=$rc $(cat "$T/calls" "$T/e")"

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
PG_CTR="spl-token-reprice-pg-$$"
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

# The prices (USD micros per million), valid before the minutes.
q "INSERT INTO model_prices (provider, model, kind, micros_per_million, currency, valid_from) VALUES
  ('anthropic','claude-haiku-4-5','llm_tokens_in',1000000,'USD','2026-10-01Z'),
  ('anthropic','claude-haiku-4-5','llm_tokens_out',5000000,'USD','2026-10-01Z'),
  ('anthropic','claude-haiku-4-5','llm_tokens_cache_read',100000,'USD','2026-10-01Z'),
  ('anthropic','claude-haiku-4-5','llm_tokens_cache_write',1250000,'USD','2026-10-01Z'),
  ('mistral','mistral-large','llm_tokens_in',500000,'USD','2026-10-01Z'),
  ('mistral','mistral-large','llm_tokens_out',1500000,'USD','2026-10-01Z'),
  ('mistral','mistral-large','llm_tokens_cache_read',50000,'USD','2026-10-01Z'),
  ('anthropic','claude-other','llm_tokens_in',1000000,'USD','2026-10-01Z')" >/dev/null
# row <agent> <vendor> <model> <minute> <in> <out> <cr> <cw> <cost> <priced>
row() {
  q "INSERT INTO fleet_token_burn_events (box_tag, agent_id, vendor, model, minute_bucket, tokens_in, tokens_out,
     cache_read, cache_write, cost_micros, currency, priced, is_metered)
     VALUES ('bx', '$1', '$2', '$3', '$4', $5, $6, $7, $8, $9, 'USD', ${10}, true)" >/dev/null
}
row c-1 claude claude-haiku-4-5-20251001 2026-10-16T10:00:00Z 1000 200 30000 400 0 false
row c-1 claude claude-haiku-4-5-20251001 2026-10-16T10:01:00Z 3 0 0 0 0 false
row m-1 mistral mistral-large 2026-10-16T11:00:00Z 2000 100 100000 0 0 false
row c-2 claude claude-haiku-4-5-20251001 2026-10-16T10:00:00Z 1000 0 0 0 777 true
row c-3 claude claude-other 2026-10-16T10:00:00Z 1000 0 0 0 0 false
row c-4 claude claude-haiku-4-5-20251001 2026-10-15T23:59:00Z 1000 0 0 0 0 false
row q-1 qwen qwen-none 2026-10-16T10:00:00Z 1000 0 0 0 0 false
cost() { q "SELECT cost_micros::float8 || '/' || priced FROM fleet_token_burn_events WHERE agent_id = '$1' AND minute_bucket = '$2'"; }
snap() { q "SELECT string_agg(agent_id || '@' || minute_bucket || '=' || cost_micros || '/' || priced, ',' ORDER BY agent_id, minute_bucket) FROM fleet_token_burn_events"; }

# runp <models> <dry>: the action's DB step, the real binary, as the runtime login
runp() {
  env FUNC="$FUNC" SPL_TR_BIN="$BIN" SPL_TR_MODELS="$1" SPL_TR_FROM=2026-10-16 SPL_TR_DRY="$2" SPL_PROXY_DSN="$RT_DSN" ENV=dev bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "$FUNC"
    _spl_token_reprice_run' >"$T/o" 2>&1
}

before="$(snap)"
runp claude-haiku-4-5-20251001,mistral-large 1; rc=$?
[[ $rc -eq 0 && "$(snap)" == "$before" ]] &&
  grep -q 'claude-haiku-4-5-20251001 unpriced_before=2 would_price=2 cost_usd=0.005503 unpriced_after=0' "$T/o" &&
  grep -q 'mistral-large unpriced_before=1 would_price=1 cost_usd=0.00615 unpriced_after=0' "$T/o" &&
  pass "B1. DRY_RUN=1 prints 2 + 1 minutes it would price, writes nothing" || fail "B1. rc=$rc $(cat "$T/o")"

runp claude-haiku-4-5-20251001,mistral-large 0; rc=$?
# 1000*1 + 200*5 + 30000*0.1 + 400*1.25 = 5500; 3; 2000*0.5 + 100*1.5 + 100000*0.05 = 6150
[[ $rc -eq 0 && "$(cost c-1 2026-10-16T10:00:00Z)" == 5500/true && "$(cost c-1 2026-10-16T10:01:00Z)" == 3/true &&
   "$(cost m-1 2026-10-16T11:00:00Z)" == 6150/true ]] && grep -q 'committed: 0 unpriced minutes left' "$T/o" &&
  pass "B2. the unpriced minutes are priced at the live pricer's cost (dated id at its base price)" ||
  fail "B2. rc=$rc $(cat "$T/o") / $(snap)"
[[ "$(cost c-2 2026-10-16T10:00:00Z)" == 777/true ]] && pass "B2. CONTROL: a priced row is untouched" || fail "B2. priced row $(cost c-2 2026-10-16T10:00:00Z)"
[[ "$(cost c-3 2026-10-16T10:00:00Z)" == 0/false ]] && pass "B2. CONTROL: another (priced) model's row is untouched" || fail "B2. other model $(cost c-3 2026-10-16T10:00:00Z)"
[[ "$(cost c-4 2026-10-15T23:59:00Z)" == 0/false ]] && pass "B2. CONTROL: a row before from is untouched" || fail "B2. before from $(cost c-4 2026-10-15T23:59:00Z)"
day="$(q "SELECT sum(cost_micros)::float8 FROM fleet_token_burn_daily WHERE day_bucket = '2026-10-16'")"
[[ "$day" == 12430 ]] && pass "B2. the day is re-rolled: 5500 + 3 + 6150 + 777 micros" || fail "B2. daily $day"

after="$(snap)"
runp claude-haiku-4-5-20251001,mistral-large 0; rc=$?
[[ $rc -eq 0 && "$(snap)" == "$after" ]] && grep -q 'claude-haiku-4-5-20251001 unpriced_before=0 priced=0 ' "$T/o" &&
  grep -q 'mistral-large unpriced_before=0 priced=0 ' "$T/o" &&
  pass "B3. a re-run prices 0 rows" || fail "B3. rc=$rc $(cat "$T/o")"

runp qwen-none 0; rc=$?
[[ $rc -ne 0 && "$(cost q-1 2026-10-16T10:00:00Z)" == 0/false ]] && grep -q '1 minute(s) found no price' "$T/o" &&
  pass "B4. CONTROL: a model with no price fails DRY_RUN=0 and stays unpriced" || fail "B4. rc=$rc $(cat "$T/o")"

(( fails == 0 )) && echo "ALL PASS" || { echo "$fails FAILED"; exit 1; }

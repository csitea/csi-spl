#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_channel_move_rehearsal_seed (spec 169 row T13), offline:
#   1. it refuses prd, a bad REHEARSAL_CMD and a bad REHEARSAL_MSGS BEFORE gcloud
#      or psql is called
#   2. a dry run calls no cloud. CONTROL for 1: dev with valid knobs is accepted
#   3. the seed SQL names only the two seed- workspaces, seats nobody, gives
#      <DST> another key than <SRC> (F10) and c-001 on its roster (W2)
#   4. the purge SQL deletes only the two seed-move- tenant rows
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0

mkdir -p "$T/stub"
for b in gcloud psql docker; do
  printf '#!/bin/sh\necho "%s $*" >>"$STUB_LOG"\nexit 1\n' "$b" >"$T/stub/$b"
  chmod +x "$T/stub/$b"
done

in_orc() {
  env PROJ_PATH="$PROJ_ROOT" APP_PATH="$APP_ROOT" SPL_STATE_DIR="$T/state/dev" STUB_LOG="$T/calls.log" \
    PATH="$T/stub:$PATH" "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    do_require_bin() { return 0; }
    for f in "$PROJ_PATH"/lib/bash/funcs/*.func.sh "$PROJ_PATH"/src/bash/run/*.func.sh; do source "$f"; done
    eval "$SNIPPET"'
}

# --- 1. refusals before any cloud call ----------------------------------------
: >"$T/calls.log"
for envs in "ENV=prd" "ENV=" "ENV=dev REHEARSAL_CMD=drop" "ENV=dev REHEARSAL_MSGS=5" "ENV=dev REHEARSAL_MSGS=1;x"; do
  # shellcheck disable=SC2086
  out=$(SNIPPET='do_spl_channel_move_rehearsal_seed; echo rc=$?' in_orc $envs DRY_RUN=0 2>&1)
  grep -q FATAL <<<"$out" && grep -q 'rc=1' <<<"$out" && pass "$envs refused" || fail "$envs not refused: $out"
done
[[ ! -s "$T/calls.log" ]] && pass "no gcloud / psql call on a refusal" || fail "a refusal called out: $(cat "$T/calls.log")"

# --- 2. a dry run calls no cloud; CONTROL for the rc=1 above --------------------
out=$(SNIPPET='do_spl_channel_move_rehearsal_seed; echo rc=$?' in_orc ENV=dev DRY_RUN=1 2>&1)
grep -q 'rc=0' <<<"$out" && grep -q 'nothing written' <<<"$out" && pass "dry run writes nothing" || fail "dry run: $out"
[[ ! -s "$T/calls.log" ]] && pass "dry run calls no cloud" || fail "dry run called out: $(cat "$T/calls.log")"

# --- 3. the seed SQL --------------------------------------------------------------
sql=$(SNIPPET='spl_cmr_args && spl_cmr_seed_sql' in_orc ENV=dev 2>&1)
grep -q 'generate_series(0, 3650 - 1)' <<<"$sql" && pass "default is 3650 posts (F13)" || fail "post count: $sql"
ten=$(grep -oE "^ *\('[a-z0-9-]+'|VALUES \('[a-z0-9-]+'|SELECT '[a-z0-9-]+'|tenant_id = '[a-z0-9-]+'" <<<"$sql" | grep -oE "'[a-z0-9-]+'" | tr -d "'" | sort -u | tr '\n' ' ')
[[ "$ten" == "seed-move-dst seed-move-src " ]] && pass "only the two seed- workspaces" || fail "tenant literals: $ten"
for t in tenant_memberships channel_humans channel_subscriptions dedicated_agents; do
  ! grep -q "INSERT INTO $t" <<<"$sql" && pass "seats nobody: no $t" || fail "the seed writes $t"
done
grep -q "('seed-move-src', 'box-seed', decode(md5('seed-move-src-pin')" <<<"$sql" &&
  grep -q "('seed-move-dst', 'box-seed', decode(md5('seed-move-dst-pin')" <<<"$sql" &&
  pass "box-seed is pinned in both under different keys (F10)" || fail "pins: $sql"
grep -q "INSERT INTO roster (tenant_id, box_id, agent_id) VALUES ('seed-move-dst', 'box-seed', 'c-001')" <<<"$sql" &&
  pass "<DST> has its orchestrator seat" || fail "roster: $sql"

# --- 4. the purge SQL -------------------------------------------------------------
sql=$(SNIPPET='spl_cmr_purge_sql' in_orc ENV=dev 2>&1)
[[ $(grep -c '^DELETE' <<<"$sql") == 1 ]] && grep -q "tenant_id IN ('seed-move-src', 'seed-move-dst') AND tenant_id LIKE 'seed-move-%'" <<<"$sql" &&
  pass "purge deletes only the two seed-move- rows" || fail "purge SQL: $sql"

# --- 5. no open tenant_hosts row for the reconcile (wf 40) -------------------------
# <first> before <then> before COMMIT, in the SQL on stdin
in_order() {
  awk -v a="$1" -v b="$2" 'index($0, a) && !x { x = NR } index($0, b) && x && !y { y = NR } /^COMMIT;/ && y && !z { z = NR } END { exit !z }'
}
sql=$(SNIPPET='spl_cmr_args && spl_cmr_seed_sql' in_orc ENV=dev 2>&1)
in_order 'INSERT INTO tenants' 'UPDATE tenant_hosts' <<<"$sql" && pass "seed closes the host row after the insert, inside its transaction" || fail "seed host row: $sql"
sql=$(SNIPPET='spl_cmr_purge_sql' in_orc ENV=dev 2>&1)
in_order 'DELETE FROM tenants' 'UPDATE tenant_hosts' <<<"$sql" && pass "purge closes the host row after the delete, inside its transaction" || fail "purge host row: $sql"
grep -q "status IN ('pending', 'failed', 'removing')" <<<"$sql" && pass "every open status is closed" || fail "statuses: $sql"

echo
((fails == 0)) && { echo "PASS: all spl-channel-move-rehearsal-seed.tst.sh assertions"; exit 0; }
echo "FAIL: $fails assertion(s)"; exit 1

#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_topic_prio_sync (spec 150 section 3.4 item 4, SPL-4813)
# calls `spool issue prio-sync` as the dispatch holder's desk and logs each
# issue whose priority follows its discussion.
#   1. DRY_RUN=1 (the default): the call carries no --apply, the lines say
#      "would move" with workspace, key, old -> new and topic
#   2. DRY_RUN=0: the call carries --apply, the lines say "moved"; it runs
#      in the lease's tenant and env as the dispatch holder
#   3. red control: a code variant that drops --apply on DRY_RUN=0 is seen
#   4. not the dispatch holder's box: no hub call; TOPIC_PRIO_FORCE=1 runs
#   5. a failed hub call or an answer that does not parse is rc 1
#   6. the cron row: manifest row topic-prio-sync every 5 min, its script is
#      executable, refuses a worktree, runs the action with DRY_RUN=0
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
FUNC="$PROJ_ROOT/src/bash/run/spl-topic-prio-sync.func.sh"
TOPIC=269d405d-d59a-4ba2-b58d-b19986580451

mkdir -p "$T/spool/dispatch"
echo "c-002@box-a 1793464017" >"$T/spool/dispatch/lease"
printf 'LEASE_ORCH=c-001\nLEASE_ENV=dev\nLEASE_TENANT=t1\n' >"$T/spool/dispatch/lease.conf"
printf '{"workspaces":["t1","csitea"],"changes":[{"workspace":"csitea","key":"SPL-7","topic":"%s","from":5,"to":1}],"unset":4,"applied":false}\n' "$TOPIC" >"$T/answer.json"

# sync [VAR=value]... [-- SNIPPET]: the action in a fresh bash with the hub
# call replaced (it records its args, env and desk in $T/calls); SNIPPET
# runs last, to plant a variant.
sync() {
  local -a vars=(); local snip=""
  while (($#)); do [[ "$1" == -- ]] && { snip="$2"; break; }; vars+=("$1"); shift; done
  env APP_PATH="$APP_ROOT" PROJ_PATH="$PROJ_ROOT" FUNC="$FUNC" T="$T" SNIPPET="$snip" \
    SPOOL_ROOT="$T/spool" SPOOL_BOX_TAG=box-a ENV= TENANT_ID= DESK_AGENT= "${vars[@]}" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    spl_dry_run() { local d="${DRY_RUN:-1}"; [[ "$d" == 0 || "$d" == 1 ]] || return 2; [[ "$d" == 1 ]]; }
    source "$FUNC"
    spl_desk_issue_run() { echo "$* | $ENV $TENANT_ID $DESK_AGENT" >>"$T/calls"; [[ -n "${HUB_FAIL:-}" ]] && return 1; cat "$T/answer.json"; }
    eval "$SNIPPET"
    do_spl_topic_prio_sync' >"$T/out" 2>&1
}
reset() { rm -f "$T/calls"; }

# --- 1. dry run ---------------------------------------------------------------
reset; sync; rc=$?
[[ $rc == 0 && "$(cat "$T/calls" 2>/dev/null)" == "prio-sync | dev t1 c-002" ]] &&
  pass "1. DRY_RUN=1 asks the hub without --apply, as the dispatch holder in the lease's tenant and env" ||
  fail "1. rc=$rc calls: $(cat "$T/calls" 2>/dev/null) out: $(cat "$T/out")"
grep -q "INFO topic-prio-sync: would move csitea SPL-7 5 -> 1 (topic $TOPIC)" "$T/out" &&
  grep -q "OK topic-prio-sync: 1 issue(s) would move across 2 workspace(s); 4 open issue(s) link no set discussion and keep their own (DRY_RUN" "$T/out" &&
  pass "1. one line per issue and the summary, marked DRY_RUN" || fail "1. lines: $(cat "$T/out")"

# --- 2. apply -----------------------------------------------------------------
reset; sync DRY_RUN=0; rc=$?
[[ $rc == 0 && "$(cat "$T/calls" 2>/dev/null)" == "prio-sync --apply | dev t1 c-002" ]] &&
  grep -q "INFO topic-prio-sync: moved csitea SPL-7 5 -> 1" "$T/out" &&
  pass "2. DRY_RUN=0 calls prio-sync --apply and logs moved" || fail "2. rc=$rc calls: $(cat "$T/calls" 2>/dev/null) out: $(cat "$T/out")"

# --- 3. red control -------------------------------------------------------------
reset; sync DRY_RUN=0 -- 'eval "$(declare -f do_spl_topic_prio_sync | sed "s/args=(--apply)/args=()/")"'
[[ "$(cat "$T/calls" 2>/dev/null)" == "prio-sync | dev t1 c-002" ]] &&
  pass "3. red control: a variant that drops --apply on DRY_RUN=0 is seen (no --apply in the call)" ||
  fail "3. red control not seen: $(cat "$T/calls" 2>/dev/null)"

# --- 4. the holder's box only ---------------------------------------------------
reset; sync DRY_RUN=0 SPOOL_BOX_TAG=box-b; rc=$?
[[ $rc == 0 && ! -e "$T/calls" ]] && grep -q "is not on this box (box-b)" "$T/out" &&
  pass "4. not the dispatch holder's box: no hub call, rc 0" || fail "4. rc=$rc $(cat "$T/out")"
reset; sync DRY_RUN=0 SPOOL_BOX_TAG=box-b TOPIC_PRIO_FORCE=1
[[ -e "$T/calls" ]] && pass "4. TOPIC_PRIO_FORCE=1 runs on another box" || fail "4. force: $(cat "$T/out")"

# --- 5. failures ----------------------------------------------------------------
reset; sync DRY_RUN=0 HUB_FAIL=1; rc=$?
[[ $rc == 1 ]] && grep -q "FATAL topic-prio-sync: spool issue prio-sync failed in t1 (dev) as c-002" "$T/out" &&
  pass "5. a failed hub call is rc 1 with one FATAL line" || fail "5. rc=$rc $(cat "$T/out")"
cp "$T/answer.json" "$T/answer.ok"; echo 'not json' >"$T/answer.json"
reset; sync DRY_RUN=0; rc=$?
[[ $rc == 1 ]] && grep -q "FATAL topic-prio-sync: the hub answer does not parse" "$T/out" &&
  pass "5. an answer that does not parse is rc 1" || fail "5. parse: rc=$rc $(cat "$T/out")"
mv "$T/answer.ok" "$T/answer.json"

# --- 6. the cron row --------------------------------------------------------------
M="$PROJ_ROOT/cnf/box-crons/box-crons.manifest"
CRON="$PROJ_ROOT/src/bash/scripts/topic-prio-sync-cron.sh"
grep -qE '^topic-prio-sync +\| \*/5 \* \* \* \* +\| src/bash/scripts/topic-prio-sync-cron.sh +\| topic-prio-sync/cron.log' "$M" &&
  pass "6. manifest row topic-prio-sync runs topic-prio-sync-cron.sh every 5 min" || fail "6. no manifest row"
[[ -x "$CRON" ]] && pass "6. the cron script is executable" || fail "6. $CRON not executable"
mkdir -p "$T/x-wt/c-1/csi-spl-orc/src/bash/scripts"; cp "$CRON" "$T/x-wt/c-1/csi-spl-orc/src/bash/scripts/"
bash "$T/x-wt/c-1/csi-spl-orc/src/bash/scripts/topic-prio-sync-cron.sh" >"$T/cout" 2>&1; rc=$?
[[ $rc == 2 ]] && grep -q 'agent worktree' "$T/cout" && pass "6. the cron script refuses an agent worktree (rc 2)" || fail "6. worktree: rc=$rc $(cat "$T/cout")"
O="$T/orc/csi-spl-orc"; mkdir -p "$O/src/bash/scripts"; cp "$CRON" "$O/src/bash/scripts/"
printf '#!/bin/bash\necho "topic-prio-sync: DRY_RUN=$DRY_RUN $*"\n' >"$O/run"; chmod +x "$O/run"
bash "$O/src/bash/scripts/topic-prio-sync-cron.sh" >"$T/cout" 2>&1; rc=$?
[[ $rc == 0 ]] && grep -q "topic-prio-sync: DRY_RUN=0 -a do_spl_topic_prio_sync" "$T/cout" &&
  pass "6. the cron runs the action with DRY_RUN=0" || fail "6. cron run: rc=$rc $(cat "$T/cout")"

echo "---"
[[ $fails == 0 ]] && echo "spl-topic-prio-sync: all passed" || echo "spl-topic-prio-sync: $fails FAILED"
exit $((fails > 0))

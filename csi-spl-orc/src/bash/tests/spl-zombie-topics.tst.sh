#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_zombie_topics (spec 166 row B6) archives, at night, the hub's
# idle topics that no open ask, live lane or open issue still names.
#   1. a fake hub list of 3 candidates, one with an open ask and one held by a
#      live lane: only the third is archived; the summary note goes to the
#      dispatch holder
#   2. red control: a variant that skips the ask check archives the topic with
#      the open ask, and this test sees that archive call
#   3. by day nothing runs: no list read, no archive, no stamp
#   4. a second tick the same night does nothing (20:30 then 06:30 CET); the
#      next night runs again
#   5. DRY_RUN=1 (the default) archives nothing and reports what it would
#   6. condition 5: an open issue whose description carries Source: /t/<uuid>
#      keeps the topic, a done one does not; a closed ask or a done lane does
#      not keep it
#   7. ZOMBIE_MAX caps the night, oldest first
#   8. not the dispatch holder's box: nothing; a lane map that read only this
#      machine (hub unreachable) stops the sweep: no archive, no stamp
#   9. a bad ZOMBIE_MAX is refused
#  10. the cron row: manifest row zombie-topics every 15 min, its script is
#      executable, refuses a worktree, passes ZOMBIE_DRY_RUN from lease.conf
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
FUNC="$PROJ_ROOT/src/bash/run/spl-zombie-topics.func.sh"
A=aaaaaaaa-0000-4000-8000-000000000001
B=aaaaaaaa-0000-4000-8000-000000000002
C=aaaaaaaa-0000-4000-8000-000000000003
D=aaaaaaaa-0000-4000-8000-000000000004
WINTER_NIGHT=2026-01-15T19:30Z

mkdir -p "$T/spool/dispatch"
echo "c-002@box-a 1793464017" >"$T/spool/dispatch/lease"
printf 'LEASE_ORCH=c-001\nLEASE_ENV=dev\nLEASE_TENANT=t1\n' >"$T/spool/dispatch/lease.conf"
printf '#!/bin/bash\necho "$*" >>"%s/sent"\n' "$T" >"$T/send.sh"

# fixtures <cands> <asks> <lanes> <issues>: the four lists the action reads.
fixtures() {
  printf '{"topics": %s}\n' "$1" >"$T/cands.json"
  printf '{"fleet": "main", "hub": "ok", "asks": %s}\n' "$2" >"$T/asks.json"
  printf '{"fleet": "main", "hub": "%s", "lanes": %s}\n' "${LANES_HUB:-ok}" "$3" >"$T/lanes.json"
  printf '{"op": "list", "result": {"issues": %s}}\n' "$4" >"$T/issues.json"
}
topic() { printf '{"task_id": "%s", "last_at": "%s"}' "$1" "$2"; }
THREE="[$(topic "$A" 2026-01-01T00:00:00Z), $(topic "$B" 2026-01-02T00:00:00Z), $(topic "$C" 2026-01-03T00:00:00Z)]"
ASK_A="[{\"ask_id\": \"ask-1\", \"state\": \"open\", \"topic\": \"$A\", \"summary\": \"x\"}]"
LANE_B="[{\"agent_id\": \"c-100\", \"agent_box\": \"box-a\", \"state\": \"live\", \"topic\": \"$B\", \"scope\": \"\", \"files\": []}]"

# sweep NOW [VAR=value]... [-- SNIPPET]: the action in a fresh bash with the
# readers, the archive and the desk replaced; SNIPPET runs last, to plant a
# variant. Archive calls land in $T/archived, reads in $T/reads.
sweep() {
  local now="$1"; shift
  local -a vars=(); local snip=""
  while (($#)); do [[ "$1" == -- ]] && { snip="$2"; break; }; vars+=("$1"); shift; done
  env APP_PATH="$APP_ROOT" PROJ_PATH="$PROJ_ROOT" RHYTHM_NOW="$now" FUNC="$FUNC" T="$T" SNIPPET="$snip" \
    SPOOL_ROOT="$T/spool" SPOOL_BOX_TAG=box-a ZOMBIE_STATE="$T/stamp" ZOMBIE_SEND_CMD="$T/send.sh" \
    ENV= TENANT_ID= DESK_AGENT= "${vars[@]}" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    spl_dry_run() { local d="${DRY_RUN:-1}"; [[ "$d" == 0 || "$d" == 1 ]] || return 2; [[ "$d" == 1 ]]; }
    source "$FUNC"
    do_spl_desk_cnf() { :; }
    spl_zombie_hub_list() { echo hub >>"$T/reads"; cat "$T/cands.json"; }
    do_spl_asks_open() { echo "INFO a log line on stdout"; cat "$T/asks.json"; }
    do_spl_lane_map() { cat "$T/lanes.json"; }
    spl_issue_list_fetch() { cat "$T/issues.json"; }
    do_spl_topic_archive() { echo "$TOPIC $MODE $DRY_RUN $DESK_AGENT $TENANT_ID $ENV" >>"$T/archived"; }
    eval "$SNIPPET"
    do_spl_zombie_topics' >"$T/out" 2>&1
}
reset() { rm -f "$T/archived" "$T/reads" "$T/stamp" "$T/sent"; }
archived() { [[ -f "$T/archived" ]] && cut -d' ' -f1 "$T/archived" | tr '\n' ' ' | sed 's/ $//'; }

# --- 1. three candidates: only the free one is archived ---------------------------
reset; fixtures "$THREE" "$ASK_A" "$LANE_B" '[]'
sweep "$WINTER_NIGHT" DRY_RUN=0; rc=$?
[[ $rc == 0 && "$(archived)" == "$C" ]] && pass "1. at night only $C is archived (A has an open ask, B a live lane)" ||
  fail "1. archived '$(archived)' rc=$rc: $(cat "$T/out")"
grep -q "^$C archive 0 c-002 t1 dev$" "$T/archived" 2>/dev/null &&
  pass "1. it archives as the dispatch holder, in the lease's tenant and env, DRY_RUN=0" || fail "1. archive call: $(cat "$T/archived" 2>/dev/null)"
grep -q "keep.$A.ask ask-1" "$T/out" && grep -q "keep.$B.lane c-100@box-a" "$T/out" &&
  pass "1. one log line per kept topic, with its reason" || fail "1. keep lines: $(cat "$T/out")"
grep -q -- "--from c-001 --to c-002@box-a --kind note --task dispatch-zombie-sweep --body zombie sweep, night of 2026-01-15 (DRY_RUN=0, cap 500, idle 7 d): 3 candidate(s), kept: ask 1, lane 1, issue 0, over the cap 0; archived 1, failed 0" "$T/sent" 2>/dev/null &&
  pass "1. one summary note to the dispatch holder, from LEASE_ORCH" || fail "1. note: $(cat "$T/sent" 2>/dev/null)"
[[ "$(cat "$T/stamp" 2>/dev/null)" == 2026-01-15 ]] && pass "1. the night is stamped 2026-01-15" || fail "1. stamp: $(cat "$T/stamp" 2>/dev/null)"

# --- 2. red control: no ask check -> the topic with the open ask is archived -------
reset; fixtures "$THREE" "$ASK_A" "$LANE_B" '[]'
sweep "$WINTER_NIGHT" DRY_RUN=0 -- 'do_spl_asks_open() { echo "{\"hub\": \"ok\", \"asks\": []}"; }'
grep -q "^$A archive" "$T/archived" 2>/dev/null &&
  pass "2. red control: a variant without the ask check archives $A, and the test sees the call" ||
  fail "2. red control did not archive $A: $(cat "$T/archived" 2>/dev/null)"

# --- 3. by day nothing runs ------------------------------------------------------
for now in 2026-01-15T18:59Z 2026-07-15T05:00Z 2026-01-15T12:00Z; do
  reset; fixtures "$THREE" '[]' '[]' '[]'
  sweep "$now" DRY_RUN=0; rc=$?
  [[ $rc == 0 && ! -e "$T/archived" && ! -e "$T/reads" && ! -e "$T/stamp" ]] && grep -q 'phase day' "$T/out" &&
    pass "3. $now is day: no list read, no archive, no stamp" || fail "3. $now: rc=$rc $(cat "$T/out")"
done

# --- 4. once a night ----------------------------------------------------------------
reset; fixtures "$THREE" '[]' '[]' '[]'
sweep 2026-01-15T19:30Z DRY_RUN=0
first="$(archived)"; rm -f "$T/archived" "$T/reads"
sweep 2026-01-16T05:30Z DRY_RUN=0; rc=$?
[[ -n "$first" && $rc == 0 && ! -e "$T/archived" && ! -e "$T/reads" ]] && grep -q 'already ran in the night of 2026-01-15' "$T/out" &&
  pass "4. a second tick the same night (06:30 CET after 20:30 CET) does nothing" || fail "4. second tick: first='$first' rc=$rc $(cat "$T/out")"
sweep 2026-01-16T19:15Z DRY_RUN=0
[[ -e "$T/archived" && "$(cat "$T/stamp")" == 2026-01-16 ]] && pass "4. the next night runs again (stamp 2026-01-16)" || fail "4. next night: $(cat "$T/out")"

# --- 5. DRY_RUN=1 archives nothing ----------------------------------------------------
reset; fixtures "$THREE" "$ASK_A" "$LANE_B" '[]'
sweep "$WINTER_NIGHT"; rc=$?
[[ $rc == 0 && ! -e "$T/archived" ]] && grep -q "PLAN archive $C" "$T/out" && ! grep -q "PLAN archive $A" "$T/out" &&
  grep -q 'would archive 1' "$T/sent" 2>/dev/null &&
  pass "5. the default DRY_RUN=1 archives nothing, plans $C, reports 'would archive 1'" || fail "5. dry: rc=$rc $(cat "$T/out" "$T/archived" 2>/dev/null)"

# --- 6. issues, closed asks, done lanes ---------------------------------------------
reset
ISS="[{\"key\": \"SPL-1\", \"status\": \"wip\", \"description\": \"Source: /t/$A\\n\\ncard\"},
      {\"key\": \"SPL-2\", \"status\": \"done\", \"description\": \"Source: /t/$B\"},
      {\"key\": \"SPL-3\", \"status\": \"todo\", \"description\": \"Mirrors x. Source: https://hub.example.com/t/$D\"}]"
ASK_DONE="[{\"ask_id\": \"ask-2\", \"state\": \"done\", \"topic\": \"$C\", \"summary\": \"\"}]"
LANE_DONE="[{\"agent_id\": \"c-101\", \"agent_box\": \"box-a\", \"state\": \"done\", \"topic\": \"$C\", \"scope\": \"\", \"files\": []}]"
fixtures "[$(topic "$A" 2026-01-01T00:00:00Z), $(topic "$B" 2026-01-02T00:00:00Z), $(topic "$C" 2026-01-03T00:00:00Z), $(topic "$D" 2026-01-04T00:00:00Z)]" \
  "$ASK_DONE" "$LANE_DONE" "$ISS"
sweep "$WINTER_NIGHT" DRY_RUN=0
[[ "$(archived)" == "$B $C" ]] && grep -q "keep.$A.issue SPL-1" "$T/out" && grep -q "keep.$D.issue SPL-3" "$T/out" &&
  pass "6. open issues SPL-1/SPL-3 keep A/D; a done issue, a done ask and a done lane keep nothing" || fail "6. archived '$(archived)': $(cat "$T/out")"

# --- 7. ZOMBIE_MAX ------------------------------------------------------------------
reset; fixtures "[$(topic "$C" 2026-01-03T00:00:00Z), $(topic "$B" 2026-01-02T00:00:00Z), $(topic "$A" 2026-01-01T00:00:00Z)]" '[]' '[]' '[]'
sweep "$WINTER_NIGHT" DRY_RUN=0 ZOMBIE_MAX=2
[[ "$(archived)" == "$A $B" ]] && grep -q "keep.$C.cap" "$T/out" &&
  pass "7. ZOMBIE_MAX=2 archives the two oldest, keeps $C over the cap" || fail "7. cap: '$(archived)' $(cat "$T/out")"
reset; sweep "$WINTER_NIGHT" ZOMBIE_MAX=
grep -q 'cap 500' "$T/sent" 2>/dev/null && pass "7. the cap defaults to cnf env.rhythm.zombie_max (500)" || fail "7. default cap: $(cat "$T/sent" "$T/out" 2>/dev/null)"

# --- 8. other box; a lane map that read only this machine ------------------------------
reset; fixtures "$THREE" '[]' '[]' '[]'
sweep "$WINTER_NIGHT" DRY_RUN=0 SPOOL_BOX_TAG=box-b; rc=$?
[[ $rc == 0 && ! -e "$T/archived" && ! -e "$T/reads" ]] && grep -q 'not on this box (box-b)' "$T/out" &&
  pass "8. not the dispatch holder's box: nothing" || fail "8. other box: rc=$rc $(cat "$T/out")"
reset; LANES_HUB=unreachable fixtures "$THREE" '[]' '[]' '[]'
sweep "$WINTER_NIGHT" DRY_RUN=0; rc=$?
[[ $rc != 0 && ! -e "$T/archived" && ! -e "$T/stamp" ]] && grep -q 'lane map was not read' "$T/out" &&
  pass "8. lane map hub unreachable: no archive, no stamp, rc=$rc" || fail "8. unreachable: rc=$rc $(cat "$T/out")"

# --- 9. refusals ---------------------------------------------------------------------
for bad in ZOMBIE_MAX=0 ZOMBIE_MAX=5001 ZOMBIE_MAX=x ZOMBIE_IDLE_DAYS=0 DRY_RUN=2; do
  reset; fixtures "$THREE" '[]' '[]' '[]'
  sweep "$WINTER_NIGHT" DRY_RUN=0 "$bad"; rc=$?
  [[ $rc != 0 && ! -e "$T/archived" ]] && pass "9. $bad refused" || fail "9. $bad: rc=$rc $(cat "$T/out")"
done

# --- 10. the cron row --------------------------------------------------------------------
M="$PROJ_ROOT/cnf/box-crons/box-crons.manifest"
CRON="$PROJ_ROOT/src/bash/scripts/zombie-topics-cron.sh"
grep -qE '^zombie-topics +\| \*/15 \* \* \* \* +\| src/bash/scripts/zombie-topics-cron.sh +\| zombie-topics/cron.log' "$M" &&
  pass "10. manifest row zombie-topics runs zombie-topics-cron.sh every 15 min" || fail "10. no manifest row"
[[ -x "$CRON" ]] && pass "10. the cron script is executable" || fail "10. $CRON not executable"
mkdir -p "$T/x-wt/c-1/csi-spl-orc/src/bash/scripts"; cp "$CRON" "$T/x-wt/c-1/csi-spl-orc/src/bash/scripts/"
bash "$T/x-wt/c-1/csi-spl-orc/src/bash/scripts/zombie-topics-cron.sh" >"$T/cout" 2>&1; rc=$?
[[ $rc == 2 ]] && grep -q 'agent worktree' "$T/cout" && pass "10. the cron script refuses an agent worktree (rc 2)" || fail "10. worktree: rc=$rc $(cat "$T/cout")"
O="$T/orc/csi-spl-orc"; mkdir -p "$O/src/bash/scripts"; cp "$CRON" "$O/src/bash/scripts/"
printf '#!/bin/bash\necho "zombie-topics: DRY_RUN=$DRY_RUN $*"\n' >"$O/run"; chmod +x "$O/run"
echo ZOMBIE_DRY_RUN=0 >>"$T/spool/dispatch/lease.conf"
SPOOL_ROOT="$T/spool" bash "$O/src/bash/scripts/zombie-topics-cron.sh" >"$T/cout" 2>&1; rc=$?
[[ $rc == 0 ]] && grep -q 'zombie-topics: DRY_RUN=0 -a do_spl_zombie_topics' "$T/cout" &&
  pass "10. ZOMBIE_DRY_RUN=0 in lease.conf runs the action with DRY_RUN=0" || fail "10. lease knob: rc=$rc $(cat "$T/cout")"
SPOOL_ROOT="$T/no-spool" bash "$O/src/bash/scripts/zombie-topics-cron.sh" >"$T/cout" 2>&1
grep -q 'zombie-topics: DRY_RUN=1 ' "$T/cout" && pass "10. no lease knob: DRY_RUN=1" || fail "10. default dry: $(cat "$T/cout")"

echo "---"
[[ $fails == 0 ]] && echo "spl-zombie-topics: all passed" || echo "spl-zombie-topics: $fails FAILED"
exit $((fails > 0))

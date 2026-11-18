#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_issue_stale_sweep (SPL-5935) ends as diss the wip issues
# whose lane is gone and was never ended, only when all nine conditions hold.
#   1. DRY_RUN=0: the one issue meeting all nine is ended (comment, then diss);
#      each issue failing just ONE condition (c1..c9) is kept, with that reason
#   2. c6 by a lane's brief on this box (no issue_key in its hub row) keeps it;
#      a done lane, a closed ask and a key that only shares a prefix do not
#   3. the cap: STALE_MAX=2 of 3 ends the 2 oldest, the third is kept "cap"
#   4. a lane map read only here (hub off), or unreadable, stops: no write
#   5. DRY_RUN=1 (the default) prints the would-end list and writes nothing
#   6. red controls: a judge variant without the c6 check ends the issue a live
#      lane names; one without the c7 check ends the issue a commit cites
#   7. STALE_MAX: 51 is refused before any read (the brief's ceiling is 50);
#      the default is 50: of 51 eligible issues 50 are ended, 1 kept "cap"
#   8. the real spl_stale_cited on a fixture repo: it fetches, then names the
#      keys of origin/master only (not a local HEAD commit); STALE_GIT_FETCH=0
#      reads the ref as it is; a failed fetch stops
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
FUNC="$PROJ_ROOT/src/bash/run/spl-issue-stale-sweep.func.sh"
JUDGE="$PROJ_ROOT/src/bash/scripts/issue-stale-sweep-judge.py"
NOW=2026-11-19T00:00:00Z OLD=2026-11-01T00:00:00Z RECENT=2026-11-17T00:00:00Z

mkdir -p "$T/spool/dispatch/briefs" "$T/spool/c-201/lifetime"
echo "c-002@box-a 1793464017" >"$T/spool/dispatch/lease"
printf 'LEASE_ORCH=c-001\nLEASE_ENV=dev\nLEASE_TENANT=t1\n' >"$T/spool/dispatch/lease.conf"
printf 'YOUR ISSUE: SPL-110 (status wip)\n' >"$T/spool/c-201/lifetime/prompt.txt"

# iss KEY [field=value]...: one issue, all nine conditions met unless overridden.
iss() {
  local key="$1"; shift
  python3 -c 'import json, sys
i = {"key": sys.argv[1], "kind": "issue", "status": "wip", "created_by": "c-002", "assignee": "c-002@box-a",
     "updated_at": sys.argv[2], "title": "Lane brief: " + sys.argv[1], "description": "## Source\n/t/x\n\n## Restart\n- next: see the brief\n"}
for kv in sys.argv[3:]:
    k, v = kv.split("=", 1); i[k] = v.replace("\\n", "\n")
print(json.dumps(i))' "$key" "$OLD" "$@"
}
ISSUES="[$(iss SPL-100), $(iss SPL-101 created_by=HUM-10), $(iss SPL-102 kind=epic), $(iss SPL-103 status=todo),
 $(iss SPL-104 assignee=HUM-10), $(iss SPL-105 'description=- next: the first answer in the topic\n- Taken by: c-002\n'),
 $(iss SPL-106), $(iss SPL-107), $(iss SPL-108), $(iss SPL-109 updated_at=$RECENT)]"
LANES='[{"agent_id": "c-300", "agent_box": "box-b", "state": "live", "issue_key": "SPL-106", "branch": "c-300-x", "files": []},
 {"agent_id": "c-301", "agent_box": "box-b", "state": "done", "issue_key": "SPL-100", "files": []}]'
ASKS='[{"ask_id": "ask-8", "state": "open", "topic": "t", "summary": "status of SPL-108?"},
 {"ask_id": "ask-9", "state": "closed", "topic": "t", "summary": "SPL-100"}]'
CITED=$'SPL-107\nSPL-1000'

# fixtures <issues> <lanes> <asks> <cited>: the four inputs the action reads.
fixtures() {
  printf '{"op": "list", "result": {"issues": %s}}\n' "$1" >"$T/issues.json"
  # one line each, as do_spl_lane_map and do_spl_asks_open print them
  printf '{"fleet": "main", "hub": "%s", "lanes": %s}\n' "${LANES_HUB:-ok}" "$2" | jq -c . >"$T/lanes.json"
  printf '{"fleet": "main", "hub": "ok", "asks": %s}\n' "$3" | jq -c . >"$T/asks.json"
  printf '%s\n' "$4" >"$T/cited.txt"
}

# sweep [VAR=value]...: the action in a fresh bash with the readers and the
# desk replaced; hub writes land in $T/writes, reads in $T/reads.
sweep() {
  env APP_PATH="$APP_ROOT" PROJ_PATH="${PROJ_OVERRIDE:-$PROJ_ROOT}" FUNC="$FUNC" T="$T" SPOOL_ROOT="$T/spool" \
    STALE_NOW="$NOW" STALE_IDLE_DAYS=7 ENV= TENANT_ID= DESK_AGENT= "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    spl_dry_run() { local d="${DRY_RUN:-1}"; [[ "$d" == 0 || "$d" == 1 ]] || return 2; [[ "$d" == 1 ]]; }
    source "$FUNC"
    do_spl_desk_cnf() { :; }
    spl_issue_list_fetch() { echo "issues $*" >>"$T/reads"; cat "$T/issues.json"; }
    do_spl_lane_map() { echo "INFO a log line"; cat "$T/lanes.json"; }
    do_spl_asks_open() { cat "$T/asks.json"; }
    spl_stale_cited() { cat "$T/cited.txt"; }
    spl_desk_issue_run() { echo "$* | $DESK_AGENT $TENANT_ID $ENV" >>"$T/writes"; }
    do_spl_issue_stale_sweep' >"$T/out" 2>&1
}
reset() { rm -f "$T/writes" "$T/reads"; }
ended() { [[ -f "$T/writes" ]] && grep -oE '^update --ref [A-Z]+-[0-9]+ --status diss' "$T/writes" | awk '{print $3}' | tr '\n' ' ' | sed 's/ $//'; }
kept() { grep -q "^keep	$1	$2	" "$T/verdict" 2>/dev/null; }
verdict() { python3 "$JUDGE" "$T/w" 50 7 "$T/spool" "$NOW" >"$T/verdict"; }
judge_in() { mkdir -p "$T/w"; cp "$T/issues.json" "$T/lanes.json" "$T/asks.json" "$T/cited.txt" "$T/w/"; verdict; }

# --- 1. one issue per condition ---------------------------------------------------
reset; fixtures "$ISSUES" "$LANES" "$ASKS" "$CITED"
sweep DRY_RUN=0; rc=$?
[[ $rc == 0 && "$(ended)" == SPL-100 ]] && pass "1. DRY_RUN=0 ends only SPL-100 (all nine held)" || fail "1. ended '$(ended)' rc=$rc: $(cat "$T/out")"
grep -q '^comment --ref SPL-100 --body Ended as diss by do_spl_issue_stale_sweep: lane gone, never ended (sweep)\. c1-c9 held.* | c-002 t1 dev$' "$T/writes" 2>/dev/null &&
  [[ "$(head -1 "$T/writes")" == comment* ]] &&
  pass "1. the reason comment goes first, as the dispatch holder in the lease's tenant and env" || fail "1. writes: $(cat "$T/writes" 2>/dev/null)"
grep -q '^issues --status wip' "$T/reads" && pass "1. it reads the wip issues" || fail "1. reads: $(cat "$T/reads")"
judge_in
for c in 1:101 2:102 3:103 4:104 5:105 6:106 7:107 8:108 9:109; do
  kept "SPL-${c#*:}" "c${c%%:*}" && pass "1. SPL-${c#*:} failing only condition ${c%%:*} is kept (c${c%%:*})" ||
    fail "1. SPL-${c#*:} not kept as c${c%%:*}: $(cat "$T/verdict")"
done
grep -q 'kept by the first failed condition: .*c6 1' "$T/out" && pass "1. the kept counts per condition are printed" || fail "1. counts: $(cat "$T/out")"

# --- 2. c6 by a brief on this box; near misses do not keep -------------------------
reset
fixtures "[$(iss SPL-110), $(iss SPL-10)]" \
  '[{"agent_id": "c-201", "agent_box": "box-a", "state": "live", "issue_key": "", "branch": "c-201-y", "files": []}]' \
  '[{"ask_id": "ask-1", "state": "open", "summary": "see SPL-1000"}]' 'SPL-100'
judge_in
kept SPL-110 c6 && grep -q 'live lane c-201@box-a' "$T/verdict" && pass "2. a lane whose seed here names SPL-110 keeps it" || fail "2. brief: $(cat "$T/verdict")"
grep -q '^end	SPL-10	' "$T/verdict" && pass "2. SPL-10 is ended: SPL-100 / SPL-1000 / SPL-110 do not name it" || fail "2. prefix: $(cat "$T/verdict")"

# --- 3. the cap --------------------------------------------------------------------
reset; fixtures "[$(iss SPL-3 updated_at=2026-11-03T00:00:00Z), $(iss SPL-1), $(iss SPL-2 updated_at=2026-11-02T00:00:00Z)]" '[]' '[]' ''
sweep DRY_RUN=0 STALE_MAX=2; rc=$?
[[ $rc == 0 && "$(ended)" == "SPL-1 SPL-2" ]] && grep -q 'cap 1' "$T/out" &&
  pass "3. STALE_MAX=2: the 2 oldest are ended, SPL-3 is kept by the cap" || fail "3. ended '$(ended)': $(cat "$T/out")"

# --- 4. a LOCAL-ONLY or unreadable lane map stops -----------------------------------
for hub in off unreachable; do
  reset; LANES_HUB=$hub fixtures "[$(iss SPL-1)]" '[]' '[]' ''
  sweep DRY_RUN=0; rc=$?
  [[ $rc != 0 && ! -e "$T/writes" ]] && grep -q "lane map was not read from every box (do_spl_lane_map hub=$hub" "$T/out" &&
    pass "4. lane map hub=$hub: the sweep stops, nothing written, it says why" || fail "4. hub=$hub rc=$rc: $(cat "$T/out")"
done
reset; fixtures "[$(iss SPL-1)]" '[]' '[]' ''; echo 'not json' >"$T/lanes.json"
sweep DRY_RUN=0; rc=$?
[[ $rc != 0 && ! -e "$T/writes" ]] && grep -q 'stopped before any write' "$T/out" &&
  pass "4. an unreadable lane map stops: nothing written" || fail "4. unreadable rc=$rc: $(cat "$T/out")"

# --- 5. DRY_RUN=1 writes nothing ---------------------------------------------------
reset; fixtures "$ISSUES" "$LANES" "$ASKS" "$CITED"
sweep; rc=$?
[[ $rc == 0 && ! -e "$T/writes" ]] && grep -q 'WOULD END SPL-100 (last update 2026-11-01T00:00:00Z) Lane brief: SPL-100 :: c1-c9 held' "$T/out" &&
  grep -q 'would end 1; nothing written' "$T/out" && pass "5. DRY_RUN=1 (default): the would-end list, no hub write" || fail "5. rc=$rc: $(cat "$T/out")"

# --- 6. red controls: code variants of the judge -----------------------------------
red() {
  mkdir -p "$T/v$1/src/bash/scripts"; sed "$2" "$JUDGE" >"$T/v$1/src/bash/scripts/issue-stale-sweep-judge.py"
  reset; fixtures "$ISSUES" "$LANES" "$ASKS" "$CITED"; PROJ_OVERRIDE="$T/v$1" sweep DRY_RUN=0
}
red 6 's/if names(text, key):/if False:/'
[[ "$(ended)" == "SPL-100 SPL-106" ]] && pass "6. red control: without the c6 check the lane's SPL-106 is ended, and the test sees it" || fail "6. c6 red: '$(ended)'"
red 7 's/if key in cited:/if False:/'
[[ "$(ended)" == "SPL-100 SPL-107" ]] && pass "6. red control: without the c7 check the cited SPL-107 is ended, and the test sees it" || fail "6. c7 red: '$(ended)'"

# --- 7. STALE_MAX: the ceiling and the default ----------------------------------------
reset; fixtures "[$(iss SPL-1)]" '[]' '[]' ''
sweep STALE_MAX=51; rc=$?
[[ $rc != 0 && ! -e "$T/reads" ]] && grep -q 'STALE_MAX must be 1..50,' "$T/out" && pass "7. STALE_MAX=51 is refused before any read" || fail "7. rc=$rc: $(cat "$T/out")"
reset; fixtures "[$(for n in $(seq 1 51); do printf '%s,' "$(iss "SPL-$((900 + n))")"; done | sed 's/,$//')]" '[]' '[]' ''
sweep DRY_RUN=0; rc=$?
[[ $rc == 0 && "$(grep -c '^update ' "$T/writes")" == 50 ]] && grep -q 'cap 1' "$T/out" && grep -q '(cap 50, idle 7 d): ended 50, failed 0' "$T/out" &&
  pass "7. the default cap is 50: of 51 eligible, 50 ended, 1 kept by the cap" || fail "7. default cap rc=$rc: $(tail -3 "$T/out")"

# --- 8. the real spl_stale_cited on a fixture repo ------------------------------------
g() { git -c user.name=t -c user.email=t@example.com -c init.defaultBranch=master "$@"; }
g init -q --bare "$T/origin.git" && g clone -q "$T/origin.git" "$T/seed" 2>/dev/null &&
  g -C "$T/seed" commit -q --allow-empty -m "fix(x, SPL-7): landed" && g -C "$T/seed" push -q origin HEAD:master &&
  g clone -q "$T/origin.git" "$T/clone" && g -C "$T/clone" commit -q --allow-empty -m "fix(x, SPL-8): local only" &&
  g -C "$T/seed" commit -q --allow-empty -m "fix(x, SPL-9): landed after the clone" && g -C "$T/seed" push -q origin HEAD:master
cited() {
  env STALE_GIT_DIR="$T/clone" FUNC="$FUNC" "$@" bash -c 'do_log() { echo "$*"; }; source "$FUNC"; spl_stale_cited' >"$T/cited.out" 2>&1
}
cited STALE_GIT_FETCH=1; rc=$?
[[ $rc == 0 && "$(tr '\n' ' ' <"$T/cited.out")" == "SPL-7 SPL-9 " ]] &&
  pass "8. after a fetch it names origin/master's SPL-7 and SPL-9, not the local HEAD's SPL-8" || fail "8. fetch rc=$rc: $(cat "$T/cited.out")"
g -C "$T/clone" update-ref refs/remotes/origin/master "$(git -C "$T/clone" rev-parse 'origin/master~1')"
cited STALE_GIT_FETCH=0; rc=$?
[[ $rc == 0 && "$(tr '\n' ' ' <"$T/cited.out")" == "SPL-7 " ]] && pass "8. STALE_GIT_FETCH=0 reads the ref as it is (no SPL-9)" || fail "8. no fetch rc=$rc: $(cat "$T/cited.out")"
g -C "$T/clone" remote set-url origin "$T/no-such.git"
cited STALE_GIT_FETCH=1; rc=$?
[[ $rc != 0 ]] && grep -q 'FATAL git fetch origin master failed' "$T/cited.out" && pass "8. a failed fetch stops" || fail "8. failed fetch rc=$rc: $(cat "$T/cited.out")"

echo "---"
[[ $fails == 0 ]] && echo "spl-issue-stale-sweep: all passed" || echo "spl-issue-stale-sweep: $fails FAILED"
exit $((fails > 0))

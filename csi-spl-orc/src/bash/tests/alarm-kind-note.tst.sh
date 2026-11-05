#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the automatic alarms reach the spool as kind note, never blocker
#          (SPL-4869, RCA 8c64225e A1.3, csi-spl-doc/specs/157-dispatch-
#          automation/rca-blocker-issues-from-agent.md section 3): the hub's
#          SweepBlockerIssues files every unanswered blocker as an SPL-2394
#          issue, and nobody answers an alarm in its topic. The ones sent to
#          the orchestrator go as --kind note --ask blocker, so their ask is
#          still journaled under $SPOOL_ROOT/asks/ and re-raised. Each case
#          runs the call site's own send helper (or the site) through the
#          REAL spool-send.sh on a sandbox root (alarm-real-send.inc.sh) and
#          reads the message that landed and the asks journal.
#   1. watchdog alarm to the orchestrator (spl_wd_send ... alarm: S2 login,
#      S2 limit, held out): note in c-001's inbox, ONE blocker ask.
#      RED controls: the old call (KIND blocker) lands a blocker; a plain
#      note to the orchestrator journals NO ask (why --ask blocker is needed)
#   2. watchdog alarm to the dispatch holder (S2 auth, orch-outcome): note,
#      no ask; with no holder it falls back to the orchestrator: note + ask
#   3. restart report (spl_ars_send ... alarm): note + ONE blocker ask; a
#      report queued as "alarm" and resent by the flush: the same
#   4. issue closer red (issue-close-landed-cron.sh): note + ONE blocker ask
#   5. epic stall (spl_epic_stall_report): note to the dispatch holder, no
#      ask (spl_spawn_q_send never journals one)
#   6. asks re-raise (spl_asks_send): note, no ask
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
# shellcheck source=alarm-real-send.inc.sh
source "$TEST_DIR/alarm-real-send.inc.sh"
fails=0
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
command -v python3 >/dev/null || { echo "FAIL: python3 is required"; exit 1; }
export SPOOL_TEST=1
RUN_DIR="$PROJ_ROOT/src/bash/run"
D="$T/a"
alarm_sandbox "$D"
seen() { echo "c-001: $(alarm_kinds "$D" c-001 | tr '\n' ' ')/ c-002: $(alarm_kinds "$D" c-002 | tr '\n' ' ')/ asks: $(alarm_asks "$D")"; }

# wd FN ARGS...: one watchdog helper call in a fresh shell, sending as c-009
wd() {
  ( set +u
    do_log() { echo "$*"; }
    # shellcheck source=../run/spl-watchdog.func.sh
    source "$RUN_DIR/spl-watchdog.func.sh"
    export SPOOL_ROOT="$D/spool" LEASE_DIR="$D/spool/dispatch" WD_DIR="$T/wd" WD_LOG="$T/wd.log" WD_SEND="$D/bin/send" WD_FROM=c-009
    "$@" )
}

# 1. watchdog alarm to the orchestrator
alarm_reset "$D"
wd spl_wd_send orchestrator alarm c-912 "WATCHDOG (093 S2): c-912 cannot act, a login screen"; rc=$?
[[ "$rc" == 0 && "$(alarm_kinds "$D" c-001)" == note && "$(alarm_asks "$D")" == "1 blocker" ]] &&
  pass "1. a watchdog alarm to the orchestrator lands as a note, its blocker ask journaled" || fail "1. alarm (rc $rc): $(seen)"
jq -e '.task_id == "wd-c-912"' "$D"/spool/c-001/inbox/*.json >/dev/null &&
  pass "1. it keeps its task wd-<id>" || fail "1. task: $(cat "$D"/spool/c-001/inbox/*.json)"
alarm_reset "$D"
wd spl_wd_send orchestrator blocker c-912 "old"
[[ "$(alarm_kinds "$D" c-001)" == blocker ]] &&
  pass "1. RED control: the old call (KIND blocker) lands a blocker, which the hub files as an SPL-2394 issue" || fail "1. control blocker: $(seen)"
alarm_reset "$D"
wd spl_wd_send orchestrator note c-912 "plain note"
[[ "$(alarm_kinds "$D" c-001)" == note && "$(alarm_asks "$D")" == "0 -" ]] &&
  pass "1. RED control: a plain note to the orchestrator journals no ask (why the alarm passes --ask blocker)" || fail "1. control note: $(seen)"

# 2. watchdog alarm to the dispatch holder, and its fallback
alarm_reset "$D"
echo "c-002 $(date +%s)" >"$D/spool/dispatch/lease"
wd bash -c 'source "'"$RUN_DIR"'/spl-watchdog.func.sh"; spl_wd_send "$(spl_wd_dispatcher)" alarm orch-outcome "WATCHDOG (SPL-1717): no outcome"' 2>/dev/null
[[ "$(alarm_kinds "$D" c-002)" == note && -z "$(alarm_kinds "$D" c-001)" && "$(alarm_asks "$D")" == "0 -" ]] &&
  pass "2. an alarm to the dispatch holder lands as a note there, no ask" || fail "2. dispatcher: $(seen)"
alarm_reset "$D"; rm -f "$D/spool/dispatch/lease"
wd bash -c 'source "'"$RUN_DIR"'/spl-watchdog.func.sh"; spl_wd_send "$(spl_wd_dispatcher)" alarm orch-outcome "WATCHDOG (SPL-1717): no outcome"' 2>/dev/null
[[ "$(alarm_kinds "$D" c-001)" == note && "$(alarm_asks "$D")" == "1 blocker" ]] &&
  pass "2. no dispatch holder: the alarm falls back to the orchestrator, a note with its blocker ask" || fail "2. fallback: $(seen)"

# 3. the restart report
ars() {
  ( set +u
    do_log() { echo "$*"; }
    # shellcheck source=../run/spl-agent-restart.func.sh
    source "$RUN_DIR/spl-agent-restart.func.sh"
    export SPOOL_ROOT="$D/spool" WD_DIR="$T/wd" WD_SEND="$D/bin/send" WD_FROM=c-009 DRY_RUN=0
    spl_peer_rlog() { :; }
    "$@" )
}
alarm_reset "$D"
ars spl_ars_send orchestrator alarm wd-c-931-20270115T0810Z "WATCHDOG RESTART (102 4.1): c-931 was restarted"; rc=$?
[[ "$rc" == 0 && "$(alarm_kinds "$D" c-001)" == note && "$(alarm_asks "$D")" == "1 blocker" ]] &&
  pass "3. the restart report lands as a note, its blocker ask journaled" || fail "3. report (rc $rc): $(seen)"
alarm_reset "$D"; mkdir -p "$T/wd/report.queue"
jq -n -c --argjson at "$(date +%s)" '{v: 1, rid: "r1", what: "the blocker", ok: "ok", to: "orchestrator", kind: "alarm", task: "wd-c-947-x", body: "WATCHDOG RESTART: c-947", flag: "", queued: $at}' \
  >"$T/wd/report.queue/r1.json"
ars spl_ars_report_flush
[[ "$(alarm_kinds "$D" c-001)" == note && "$(alarm_asks "$D")" == "1 blocker" && -z "$(ls -A "$T/wd/report.queue")" ]] &&
  pass "3. a queued alarm report, resent by the flush: a note with its blocker ask" || fail "3. flush: $(seen) / $(ls -A "$T/wd/report.queue")"

# 4. the issue closer's red alarm (a fake orc tree whose ./run fails)
F="$T/fake/x-y-orc"
mkdir -p "$F/src/bash/scripts" "$F/lib/bash/funcs"
cp "$PROJ_ROOT/src/bash/scripts/issue-close-landed-cron.sh" "$F/src/bash/scripts/"
cp "$PROJ_ROOT/lib/bash/funcs/spl-desk-agents.func.sh" "$F/lib/bash/funcs/"
printf '#!/bin/sh\nexit 1\n' >"$F/run"; chmod +x "$F/run"
alarm_reset "$D"; printf 'SPOOL_BOX_TAG=box-a\n' >"$D/spool/box.env"
out="$(CRON_LOG="$T/cron.log" SPOOL_ROOT="$D/spool" ISSUE_CLOSE_SEND="$D/bin/send" ISSUE_CLOSE_STATE_DIR="$T/icl" \
  ISSUE_CLOSE_ALERT_AFTER=1 ISSUE_CLOSE_ALERT_FROM=c-009 bash "$F/src/bash/scripts/issue-close-landed-cron.sh" 2>&1)"
[[ "$(alarm_kinds "$D" c-001)" == note && "$(alarm_asks "$D")" == "1 blocker" ]] &&
  jq -e '.task_id == "dispatch-issue-closer"' "$D"/spool/c-001/inbox/*.json >/dev/null &&
  pass "4. the issue closer's red alarm lands as a note on dispatch-issue-closer, its blocker ask journaled" || fail "4. closer: $(seen) / $out"

# 5. the epic stall report (sent from the orch holder to the dispatch holder)
alarm_reset "$D"
row='[{"key":"SPL-100","title":"t","topic":"11111111-2222-4333-8444-555555555555","open":2,"total":3,"last_key":"SPL-101","last_at":"2026-11-05T10:00:00Z","idle_min":90,"next":[{"key":"SPL-102","status":"todo","title":"n"}]}]'
printf '%s\n' "$row" >"$T/stalled.json"
out="$( ( set +u
  do_log() { echo "$*"; }
  source "$RUN_DIR/spl-spawn-queue.func.sh"; source "$RUN_DIR/spl-epic-stall-check.func.sh"
  export SPOOL_ROOT="$D/spool" SPAWN_QUEUE_SEND="$D/bin/send" ASKS_BOX=box-a DRY_RUN=0 PROJ_PATH="$PROJ_ROOT"
  spl_epic_stall_report "$T/stalled.json" c-009@box-a c-002 ) 2>&1)"
[[ "$(alarm_kinds "$D" c-002)" == note && "$(alarm_asks "$D")" == "0 -" ]] && grep -q 'OK epic SPL-100 stalled' <<<"$out" &&
  pass "5. the epic stall alarm lands as a note at the dispatch holder, no ask" || fail "5. epic stall: $(seen) / $out"

# 6. the asks re-raise
alarm_reset "$D"
out="$( ( set +u
  do_log() { echo "$*"; }
  source "$RUN_DIR/spl-asks-tick.func.sh"
  export SPOOL_ROOT="$D/spool" ASKS_SEND="$D/bin/send" ASKS_BOX=box-a PROJ_PATH="$PROJ_ROOT"
  spl_asks_send c-002@box-a "**ASKS: 1 open ask**" c-009 ) 2>&1)"; rc=$?
[[ "$rc" == 0 && "$(alarm_kinds "$D" c-002)" == note && "$(alarm_asks "$D")" == "0 -" ]] &&
  pass "6. the asks re-raise lands as a note, no ask" || fail "6. re-raise (rc $rc): $(seen) / $out"

[[ "$fails" == 0 ]] && echo "ALL PASS" || { echo "FAILED: $fails"; exit 1; }

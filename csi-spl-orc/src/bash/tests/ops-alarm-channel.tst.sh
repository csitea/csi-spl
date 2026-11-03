#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-4700 (owner HUM-10, t1 3a18a0b5 msg 6a43f1a2: "the failover
#          flips and automated msgs should go to the alerts channel"). Every
#          automatic poster that went to #spool-hub-ops reads its channel from
#          the REAL cnf of this tree and lands in #alerts. Nothing is posted:
#          the poster is stubbed (FLEET_NOTICE_CMD, do_spl_desk_post).
#     1. do_spl_fleet_notice (failover, ROTATION FAILED, recovered, a hung
#        watchdog) -> #alerts, from all.env.yaml and the rendered dev / prd json
#     2. do_spl_deploy_lag_alarm -> #alerts
#     3. do_spl_deploy_failure_post -> #alerts
#     4. do_spl_deploy_failure_poll (through do_spl_deploy_failure_post) -> #alerts
#     5. an explicit DESK_CHANNEL still wins; an unset env.ops_alarms.channel
#        is a FATAL with nothing posted (no literal default)
#     6. no literal spool-hub-ops channel default is left in these posters
#     7. the weekly scan (weekly-full-scan-cron.sh, DRY_RUN=1, scan stubbed by
#        WEEKLY_SCAN_CMD): a missed week's blocker -> #alerts, the weekly
#        summary stays on #spool-hub-ops (spec 146 table)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
REPO=$(cd "$PROJ_ROOT/.." && pwd)
CNF_DIR="$REPO/csi-spl-cnf/csi-spl"
RUN_DIR="$PROJ_ROOT/src/bash/run"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }
eq() { [ "$2" = "$3" ] && pass "$1" || fail "$1" "want '$2' got '$3'"; }

command -v yq >/dev/null 2>&1 || { echo "SKIP: yq is not on PATH"; exit 0; }

do_log() { :; }
do_require_bin() { :; }
# shellcheck source=../../../lib/bash/funcs/spl-ops-alarm-channel.func.sh
. "$PROJ_ROOT/lib/bash/funcs/spl-ops-alarm-channel.func.sh"
for f in spl-fleet-notice spl-deploy-lag-alarm spl-deploy-failure-post spl-deploy-failure-poll; do
  # shellcheck source=/dev/null
  . "$RUN_DIR/$f.func.sh"
done

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
POSTS="$T/posts"
do_spl_desk_post() { printf '%s|%s\n' "${DESK_CHANNEL:-}" "${DESK_KIND:-}" >>"$POSTS"; return 0; }
last_post() { tail -1 "$POSTS" 2>/dev/null; }

# 1. the fleet notices, from each file the actions read
printf '#!/bin/sh\necho "$1" >>"%s/notice.log"\n' "$T" >"$T/notice"; chmod +x "$T/notice"
for cnf in all.env.yaml dev.env.json prd.env.json; do
  rm -f "$T/notice.log"
  # shellcheck disable=SC2034 # SPL_CNF is read by do_spl_fleet_notice
  ( do_spl_desk_cnf() { SPL_CNF="$CNF_DIR/$cnf"; }
    ENV=dev TENANT_ID=t1 DESK_AGENT=g-001 DESK_BODY="Orchestrator failover: g-001@sat took over" \
      FLEET_NOTICE_CMD="$T/notice" do_spl_fleet_notice ) >/dev/null 2>&1
  eq "1. a fleet notice from $cnf goes to #alerts" alerts "$(cat "$T/notice.log" 2>/dev/null)"
done

# 2. the deploy lag alarm
: >"$POSTS"; printf 'dev hub lagging served=aaaa sha=bbbb\n' >"$T/lag"
ENV=dev OPS_STATE_FILE="$T/lag.state" OPS_LAG_CMD="cat '$T/lag'" do_spl_deploy_lag_alarm >/dev/null 2>&1
eq "2. the deploy lag alarm is a blocker in #alerts" "alerts|blocker" "$(last_post)"

# 3. a failed deploy run
: >"$POSTS"
FAIL_RUN_URL=https://x/runs/1 FAIL_COMMIT_SUBJECT="fix(hub, SPL-1): x" do_spl_deploy_failure_post >/dev/null 2>&1
eq "3. a failed deploy run is a blocker in #alerts" "alerts|blocker" "$(last_post)"

# 4. the failure poll, end to end through the real failure post
: >"$POSTS"; printf '201\t20 hub\thttps://x/runs/201\tabc123\tfix(hub, SPL-2): y\thub-pg\n' >"$T/rows"
FAIL_POLL_STATE="$T/poll.state" FAIL_POLL_LIST_CMD="cat '$T/rows'" do_spl_deploy_failure_poll >/dev/null 2>&1
eq "4. the failure poll posts its blocker in #alerts" "alerts|blocker" "$(last_post)"

# 5. DESK_CHANNEL wins; an unset key is a FATAL, nothing posted
eq "5. an explicit DESK_CHANNEL wins" ops-test "$(DESK_CHANNEL='#ops-test' spl_ops_alarm_channel 2>/dev/null)"
printf 'env: {}\n' >"$T/empty.yaml"; : >"$POSTS"
OPS_ALARM_CNF="$T/empty.yaml" FAIL_RUN_URL=https://x/runs/3 do_spl_deploy_failure_post >"$T/o" 2>&1; rc=$?
[[ "$rc" != 0 && ! -s "$POSTS" ]] && grep -q 'FATAL env.ops_alarms.channel is not set' "$T/o" &&
  pass "5. no env.ops_alarms.channel: FATAL, nothing posted" || fail "5. unset key" "rc=$rc posts=$(cat "$POSTS") out=$(cat "$T/o")"

# 6. no literal channel default left in the posters
left="$(grep -n 'spool-hub-ops' "$RUN_DIR"/spl-deploy-{lag-alarm,failure-post,failure-poll}.func.sh \
  "$PROJ_ROOT/src/bash/scripts/spl-ops-alarm-cron.sh" 2>/dev/null)"
eq "6. no spool-hub-ops literal in the deploy alarm posters" "" "$left"

# 7. the weekly scan: the missed-week blocker is an alarm, the summary a report
mkdir -p "$T/ws"
out="$(WEEKLY_SCAN_DIR="$T/ws" DRY_RUN=1 \
  WEEKLY_SCAN_CMD='echo "week 44 skipped" >"$WEEKLY_SCAN_DIR/$WEEKLY_SCAN_DATE.missed.txt"; echo ok >"$WEEKLY_SCAN_DIR/$WEEKLY_SCAN_DATE.summary.txt"' \
  bash "$REPO/csi-spl-iac/src/bash/scripts/weekly-full-scan-cron.sh" 2>&1)"
grep -q '^DRY_RUN would post a blocker to #alerts: week 44 skipped$' <<<"$out" &&
  pass "7. the weekly scan's missed-week blocker goes to #alerts" || fail "7. missed-week blocker" "$out"
grep -q 'summary.txt to #spool-hub-ops of t1' <<<"$out" &&
  pass "7. the weekly scan summary stays on #spool-hub-ops" || fail "7. weekly summary" "$out"

echo "ops-alarm-channel: $fails failure(s)"
[ "$fails" -eq 0 ]

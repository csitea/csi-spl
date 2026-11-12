#!/usr/bin/env bash
# weekly-full-scan-cron.sh -- the box cron of the weekly full scan (owner
# 2026-10-01: "use 1, but make it friday at 17:00"; moved to Friday 21:00 box
# time, the night, by spec 166 row B7). It runs
# do_check_weekly_full_scan (every scanner, whole scope, csi-spl + csi-web) and
# posts the short summary to #spool-hub-ops as the seated CI ops desk, only so
# the result is visible: no triage, no issues. A skipped week is an alarm: its
# blocker goes to cnf env.ops_alarms.channel (#alerts, SPL-4700), not --channel.
#
#   weekly-full-scan-cron.sh [--tenant t1] [--agent c-685] [--box box-ci]
#                            [--channel spool-hub-ops]
#
# DRY_RUN=1 (the default) prints the scan plan and what it would post; the
# crontab line sets DRY_RUN=0. Exit: 0 ok (or another run holds the lock),
# 1 the scan or the post failed, 2 usage, 3 a required tool is missing.
set -uo pipefail

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"          # .../csi-spl-iac -> repo root
# SPL_OPS_AGENT, the CI ops desk's id: its one home.
# shellcheck source=../../../../csi-spl-orc/lib/bash/funcs/spl-desk-agents.func.sh
. "$ROOT/csi-spl-orc/lib/bash/funcs/spl-desk-agents.func.sh"
# spl_ops_alarm_channel: the missed-week blocker's channel (SPL-4700).
# shellcheck source=../../../../csi-spl-orc/lib/bash/funcs/spl-ops-alarm-channel.func.sh
. "$ROOT/csi-spl-orc/lib/bash/funcs/spl-ops-alarm-channel.func.sh"

TENANT="t1" AGENT="$SPL_OPS_AGENT" BOX="box-ci" CHANNEL="spool-hub-ops"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tenant)  TENANT="${2:?}"; shift 2 ;;
    --agent)   AGENT="${2:?}"; shift 2 ;;
    --box)     BOX="${2:?}"; shift 2 ;;
    --channel) CHANNEL="${2:?}"; shift 2 ;;
    *) echo "weekly-full-scan-cron: unknown arg $1" >&2; exit 2 ;;
  esac
done

# cron runs with PATH=/usr/bin:/bin; the scanners live in /usr/local/bin and
# ~/.local/bin (do_install_lint_tools).
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin"
# gh reads GH_TOKEN from the box's one GitHub credential file (SPL-5366); a
# scan goes on without it, only its gh steps then report the missing token
. "$HERE/../../../lib/bash/funcs/gh-box-token.func.sh"
gh_box_token_export || echo "weekly-full-scan-cron: WARN no GitHub token for gh: put $(gh_box_token_var) in $(gh_box_token_file)" >&2
DRY_RUN="${DRY_RUN:-1}"

for t in git python3 flock; do
  command -v "$t" >/dev/null 2>&1 || { echo "weekly-full-scan-cron: FATAL missing $t" >&2; exit 3; }
done

dir="${WEEKLY_SCAN_DIR:-${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/weekly-scan}"
mkdir -p "$dir" || exit 1
exec 9>"$dir/.lock"
flock -n 9 || { echo "weekly-full-scan-cron: another scan holds the lock"; exit 0; }

date="$(date +%F)"
echo "== weekly full scan $(date -Is) DRY_RUN=$DRY_RUN"
# WEEKLY_SCAN_CMD replaces the scan (tests); it runs in csi-spl-iac.
( cd "$ROOT/csi-spl-iac" && export DRY_RUN WEEKLY_SCAN_DIR="$dir" WEEKLY_SCAN_DATE="$date" \
    && eval "${WEEKLY_SCAN_CMD:-./run -a do_check_weekly_full_scan}" ) || { echo "weekly-full-scan-cron: the scan failed"; exit 1; }

summary="$dir/$date.summary.txt"
missed="$dir/$date.missed.txt"
post() {  # <channel> <kind> <body>
  ( cd "$ROOT/csi-spl-orc" && TENANT_ID="$TENANT" DESK_AGENT="$AGENT" DESK_BOX="$BOX" DESK_CHANNEL="$1" \
      DESK_KIND="$2" DESK_BODY="$3" DRY_RUN=0 ./run -a do_spl_desk_post )
}
alarm_channel=""
[ -s "$missed" ] && alarm_channel="$(spl_ops_alarm_channel)"
if [ "$DRY_RUN" != 0 ]; then
  [ -s "$missed" ] && echo "DRY_RUN would post a blocker to #${alarm_channel:-?}: $(<"$missed")"
  echo "DRY_RUN would post $summary to #$CHANNEL of $TENANT as $AGENT on $BOX"
  exit 0
fi
# a skipped week first, as its own one-line blocker, in the ops alarm channel
[ -s "$missed" ] && { { [ -n "$alarm_channel" ] && post "$alarm_channel" blocker "$(<"$missed")"; } \
  || echo "weekly-full-scan-cron: the missed-week alert failed"; }
[ -s "$summary" ] || { echo "weekly-full-scan-cron: no summary at $summary"; exit 1; }
post "$CHANNEL" note "$(<"$summary")" \
  || { echo "weekly-full-scan-cron: the post failed (the report is still at ${summary%.summary.txt}.md)"; exit 1; }
echo "== posted $summary"

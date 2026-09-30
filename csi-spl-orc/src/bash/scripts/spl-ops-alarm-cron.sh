#!/usr/bin/env bash
# spl-ops-alarm-cron.sh (SPL-1254 + SPL-1255) — the box cron that posts deploy
# alarms to #spool-hub-ops, every 10 min, as the seated CI ops desk. The owner
# chose a box cron over GitHub workflows (OPS-01 on box-ci in t1, key on the box;
# no repo secret), 2026-09-30.
#
# Each tick:
#   SPL-1254  do_spl_deploy_lag_alarm for each env (dev, prd) -- posts one blocker
#             when an env starts lagging and one recovery when it is current
#             again (edge-dedup, so no repeat every 10 min).
#   SPL-1255  do_spl_deploy_failure_poll -- polls gh for FAILED 20/30 runs and
#             posts one blocker per NEW failure (edge-dedup by run id).
#
# It is DRY_RUN=1 unless told otherwise, so an accidental interactive run prints
# what it WOULD post and sends nothing; the crontab entry sets DRY_RUN=0.
#
#   spl-ops-alarm-cron.sh [--envs dev,prd] [--tenant t1] [--agent OPS-01]
#                         [--box box-ci] [--print-crontab] [--check-tools]
#
# Exit: 0 ok (or another tick holds the lock), 1 an alarm/poll failed,
#       2 usage, 3 a required tool is missing.
set -uo pipefail

ENVS="dev,prd" TENANT="t1" AGENT="OPS-01" BOX="box-ci" PRINT_CRONTAB=0 CHECK_TOOLS=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --envs)  ENVS="${2:?}"; shift 2 ;;
    --tenant) TENANT="${2:?}"; shift 2 ;;
    --agent) AGENT="${2:?}"; shift 2 ;;
    --box)   BOX="${2:?}"; shift 2 ;;
    --print-crontab) PRINT_CRONTAB=1; shift ;;
    --check-tools)   CHECK_TOOLS=1; shift ;;
    -h|--help) sed -n '/^#   spl-ops-alarm-cron.sh/,/^#$/p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2 ;;
    *) echo "spl-ops-alarm-cron: unknown arg $1" >&2; exit 2 ;;
  esac
done

HERE="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ROOT="$(cd "$HERE/../../../.." && pwd)"           # .../csi-spl-orc -> repo root
RUN="$ROOT/csi-spl-orc/run"

if [ "$PRINT_CRONTAB" = 1 ]; then
  printf '*/10 * * * * DRY_RUN=0 %s --envs %s --tenant %s --agent %s --box %s >> %s/.cache/csi-spl/ops-alarm-cron.log 2>&1\n' \
    "$HERE/spl-ops-alarm-cron.sh" "$ENVS" "$TENANT" "$AGENT" "$BOX" "$HOME"
  exit 0
fi

# CRON'S PATH IS NOT YOUR PATH (see desk-reconcile-cron.sh): vixie cron runs with
# PATH=/usr/bin:/bin, but gh/yq/go/pnpm live elsewhere. Set it here, and add the
# user-local bin where gh often is.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:$HOME/.local/bin${DESK_CRON_PATH_EXTRA:+:$DESK_CRON_PATH_EXTRA}"
export GH_TOKEN="${GH_TOKEN:-$(cat "$HOME/.github/token" 2>/dev/null || true)}"

need_missing=""
for t in git python3; do command -v "$t" >/dev/null 2>&1 || need_missing="$need_missing $t"; done
[ -x "$RUN" ] || need_missing="$need_missing $RUN"
if [ -n "$need_missing" ]; then echo "spl-ops-alarm-cron: FATAL missing:$need_missing" >&2; exit 3; fi
if [ "$CHECK_TOOLS" = 1 ]; then echo "spl-ops-alarm-cron: tools ok; run=$RUN envs=$ENVS agent=$AGENT box=$BOX tenant=$TENANT"; exit 0; fi

# One tick at a time.
LOCK="${XDG_CACHE_HOME:-$HOME/.cache}/csi-spl/ops-alarm-cron.lock"
mkdir -p "$(dirname "$LOCK")" 2>/dev/null || true
exec 9>"$LOCK" 2>/dev/null || true
if command -v flock >/dev/null 2>&1 && ! flock -n 9; then
  echo "spl-ops-alarm-cron: another tick holds the lock -- skipping"; exit 0
fi

echo "== spl-ops-alarm-cron $(date -u +%FT%TZ) envs=$ENVS agent=$AGENT box=$BOX tenant=$TENANT dry=${DRY_RUN:-1} =="
rc=0

# SPL-1254: per-env deploy-lag alarm.
IFS=',' read -r -a env_list <<<"$ENVS"
for e in "${env_list[@]}"; do
  [ -n "$e" ] || continue
  ENV="$e" TENANT_ID="$TENANT" DESK_AGENT="$AGENT" DESK_BOX="$BOX" DESK_CHANNEL=spool-hub-ops \
    "$RUN" -a do_spl_deploy_lag_alarm || { echo "spl-ops-alarm-cron: lag alarm FAILED for $e"; rc=1; }
done

# SPL-1255: failed 20/30 run poll.
TENANT_ID="$TENANT" DESK_AGENT="$AGENT" DESK_BOX="$BOX" DESK_CHANNEL=spool-hub-ops \
  "$RUN" -a do_spl_deploy_failure_poll || { echo "spl-ops-alarm-cron: failure poll FAILED"; rc=1; }

echo "== spl-ops-alarm-cron done rc=$rc =="
exit "$rc"

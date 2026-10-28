#!/usr/bin/env bash
# reliability-check-cron.sh - run one check of the reliability round (spec 146,
# SPL-4064) from the box user's crontab. Each check is a csi-spl-utl action;
# a thin rel-<row>-cron.sh per row of cnf/box-crons/box-crons.manifest calls
# this script with its row name, so do_install_box_crons installs them as
# `# csi-spl:box-cron:rel-<row>` lines. Row 10 (do_cloud_sql_backup_verify)
# is no box job: it runs in the daily workflow 45_db-backup.yml.
#
#   reliability-check-cron.sh <row>
#
# Every check runs with DRY_RUN=0, which for the alert-only rows means: send
# the throttled spool note to the orchestrator. The only row that changes
# anything is rel-docker-prune, which removes the labelled test containers of
# a gone lane older than 2 h, as its row (spec 146 T007) approved. One run per
# row at a time (flock), each under REL_CRON_TIMEOUT seconds. When the run
# ends, the row's beat is written for the cron snitch (row 11).
#
# Exit: 0 ran (or another run held the lock), 1 the check alerted or failed,
# 2 usage or a refusal, 3 a tool this needs is not on the PATH.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# rel_action <row> - the csi-spl-utl action of a row; the one place a row
# names its check
rel_action() {
  case "$1" in
    systemd-unit)     echo do_os_systemd_unit_check ;;
    reboot-required)  echo do_os_reboot_required_check ;;
    cert-expiry)      echo do_net_cert_expiry_check ;;
    external-api)     echo do_net_external_api_check ;;
    tmux-health)      echo do_fleet_tmux_health_guard ;;
    orphan-process)   echo do_fleet_orphan_process_reap ;;
    docker-prune)     echo do_docker_test_container_prune ;;
    gh-runner)        echo do_gh_runner_health_check ;;
    clock-sync)       echo do_os_clock_sync_check ;;
    cron-snitch)      echo do_cron_heartbeat_snitch ;;
    box-beat)         echo do_box_beat_telemetry_check ;;
    *) return 1 ;;
  esac
}

row="${1:-}"
action="$(rel_action "$row")" || { echo "reliability-check-cron: unknown row '$row'" >&2; exit 2; }

missing=""
for t in flock timeout; do command -v "$t" >/dev/null 2>&1 || missing="$missing $t"; done
[ -z "$missing" ] || { say "FATAL these tools are not on the PATH:$missing (PATH=$PATH)"; exit 3; }

ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
UTL="${REL_CRON_UTL:-$ORC/../csi-spl-utl}"
case "$ORC" in
  *-wt/*) [ "${REL_CRON_ALLOW_WORKTREE:-0}" = 1 ] || { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$UTL/run" ] || { say "FATAL $UTL/run not found or not executable"; exit 2; }

SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}"; export SPOOL_ROOT
# the box id of this desk (box.env), so the checks name the box as the
# uplink probe does, not by its hostname
box="$(sed -n 's/^SPOOL_DESK_BOX=//p' "$SPOOL_ROOT/box.env" 2>/dev/null | tail -1)"
if [ -n "$box" ]; then
  DEV_BOX="${DEV_BOX:-$box}"; UPLINK_PROBE_BOX="${UPLINK_PROBE_BOX:-$box}"
  export DEV_BOX UPLINK_PROBE_BOX
fi
# gh with no login reads GH_TOKEN from the box user's own token file (as
# ci-red-note-cron.sh)
if [ "$row" = gh-runner ] && [ -z "${GH_TOKEN:-}" ]; then
  tf="${REL_CRON_GH_TOKEN_FILE:-$HOME/.github/token}"
  if ! gh auth status >/dev/null 2>&1 && [ -r "$tf" ]; then GH_TOKEN="$(cat "$tf")"; export GH_TOKEN; fi
fi

lock="${REL_CRON_LOCK_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl}/rel-$row.lock"
if ! mkdir -p "$(dirname "$lock")" 2>/dev/null || ! { exec 9>"$lock"; } 2>/dev/null; then
  say "FATAL cannot open the lock $lock"; exit 2
fi
flock -n 9 || { say "OK another rel-$row run holds $lock"; exit 0; }

( cd "$UTL" && DRY_RUN="${REL_CRON_DRY_RUN:-0}" timeout "${REL_CRON_TIMEOUT:-300}" ./run -a "$action" 2>&1 ) |
  grep -vE '^\[?(INFO|DEBUG)' | grep . | sed "s/^/$(date -u +%Y-%m-%dT%H:%M:%SZ) rel-$row /"
rc="${PIPESTATUS[0]}"
bash "$UTL/src/bash/run/cron-heartbeat-snitch.func.sh" --beat "box-cron:rel-$row" "$rc" >/dev/null 2>&1 || true
[ "$rc" = 0 ] || { say "rel-$row $action rc=$rc"; exit 1; }

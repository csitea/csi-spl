#!/usr/bin/env bash
# desk-reconcile-cron.sh — keep every live agent on this box seated at the hub,
# from the box user's crontab.
#
# WHY THIS EXISTS
#   Twice now (2026-09-21 and 2026-09-22) every agent on this box read OFFLINE
#   on dev.spool-hub until a human noticed and re-seated them by hand. The
#   owner's words the second time: "once again the connections to the spool-hub
#   dev do not work ... all of the spuwn agents should be online for the
#   dev.spool-hub". That is a durability requirement, not a request for one
#   more manual recovery.
#
# WHAT KILLS A DESK, and why a boot hook alone does not cover it
#   A desk is two things: a `spool hub-run` sidecar (a detached process) and an
#   agent's tmux pane. The sidecar dies with the box; the panes die with the
#   TMUX SERVER, which on this box restarts far more often than the box does -
#   that is what happened on 2026-09-22, with no reboot involved. Worse, agents
#   are spawned all day, and an agent spawned after the last reconcile has no
#   desk at all. So the thing that has to run repeatedly is a RECONCILE, and
#   @reboot is at best a special case of it arriving early.
#
# WHY CRON AND NOT A SYSTEMD USER SERVICE
#   Measured on this box 2026-09-22: `loginctl show-user <box user>` reports
#   Linger=no, and a `systemctl --user` call over a sudo hop fails with "$
#   DBUS_SESSION_BUS_ADDRESS and $XDG_RUNTIME_DIR not defined". A user unit
#   would therefore need `loginctl enable-linger`, which is root, box-wide and
#   permanent; a system unit needs root to write under /etc. Cron needs
#   neither, the box user already has a crontab, and the neighbouring project
#   on this box drives its own 5-minute watchdog exactly this way. Nothing here
#   wants the one thing systemd would add - a supervised long-lived process -
#   because the reconcile is a short command, not a daemon.
#
# WHAT IT CANNOT DO — say it rather than let a reader assume it
#   It runs on ONE box, from ONE crontab. If the crontab entry is removed, or
#   points at a deleted worktree, this reports nothing and its silence looks
#   exactly like health. do_spl_desk_install_service --check answers "is it
#   still installed"; nothing answers it automatically.
#
#   desk-reconcile-cron.sh [--env dev] [--tenant t1] [--print-crontab]
#
# Exit: 0 reconciled (or another tick held the lock), 1 something was not
# seated, 2 usage or a refusal.
set -uo pipefail

ENV_NAME="${ENV:-dev}"
TENANT="${TENANT_ID:-t1}"
PRINT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --env) ENV_NAME="${2:?}"; shift 2 ;;
    --tenant) TENANT="${2:?}"; shift 2 ;;
    --print-crontab) PRINT=1; shift ;;
    -h|--help) sed -n '36p' "$0" | sed 's/^# *//'; exit 2 ;;
    *) echo "desk-reconcile-cron: unknown argument: $1" >&2; exit 2 ;;
  esac
done

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)/$(basename "${BASH_SOURCE[0]}")"
# <repo>/csi-spl-orc/src/bash/scripts -> <repo>
ORC="$(cd "$(dirname "$SELF")/../../.." && pwd)"
ROOT="$(cd "$ORC/.." && pwd)"
say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

# A crontab line that points into an agent worktree keeps working right up
# until that agent finishes and its worktree is removed, and then stops
# silently while still looking installed. Refuse rather than inherit that -
# and refuse to PRINT one too, because the printed line is what gets installed.
case "$ROOT" in
  *-wt/*)
    if [ "${DESK_ALLOW_WORKTREE:-0}" = 1 ]; then
      say "WARN running from the agent worktree $ROOT because DESK_ALLOW_WORKTREE=1."
      say "WARN That is for verifying this script only. NEVER put it in a crontab line."
    else
      say "FATAL $ROOT is an agent worktree - install the cron against the shared checkout"
      exit 2
    fi
    ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

if [ "$PRINT" = 1 ]; then
  # <org>-<app> from the module dir, like every other name in this tree, so a
  # fork of this repo does not fight this one over the same crontab line.
  ORG_APP="$(basename "$ORC")"; ORG_APP="${ORG_APP%-orc}"
  printf '*/5 * * * * ENV=%s TENANT_ID=%s %s >> %s/cron.out 2>&1 # %s:desk-reconcile\n' \
    "$ENV_NAME" "$TENANT" "$SELF" \
    "${DESK_CRON_LOG_DIR:-/var/${ORG_APP%%-*}/$ORG_APP/desk-reconcile}" "$ORG_APP"
  exit 0
fi

say "INFO reconciling desks: env=$ENV_NAME tenant=$TENANT orc=$ORC"
( cd "$ORC" && env ENV="$ENV_NAME" TENANT_ID="$TENANT" DRY_RUN=0 ./run -a do_spl_desk_up_all )
rc=$?
say "INFO do_spl_desk_up_all exit $rc"
exit "$rc"

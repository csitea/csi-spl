#!/usr/bin/env bash
# outlook-import-cron.sh — run do_spl_calendar_outlook_tick from the box
# user's crontab every :00 and :30 (spec 180 FR-10, T5): inside the window
# (06:30-20:30 Europe/Helsinki, Monday to Friday; the action checks it) each
# tick exports the Outlook calendar through the box link and imports it.
# Installed by do_install_box_crons as the manifest row outlook-import
# (cnf/box-crons/box-crons.manifest), tagged `# csi-spl:box-cron:outlook-import`.
# A box with no box-local env file (see do_spl_calendar_outlook_tick) has
# nothing to sync and exits 0.
#
#   outlook-import-cron.sh
#
# Exit: 0 ran, 1 the action failed, 2 usage or a refusal.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

[ "$#" = 0 ] || { echo "outlook-import-cron: unknown argument: $1" >&2; exit 2; }
ORC="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../../.." && pwd)"
case "$ORC" in
  *-wt/*)
    [ "${OUTLOOK_IMPORT_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }
say "START outlook-import"
( cd "$ORC" && DRY_RUN=0 ./run -a do_spl_calendar_outlook_tick ); rc=$?
say "STOP outlook-import rc=$rc"
[ "$rc" = 0 ] || exit 1

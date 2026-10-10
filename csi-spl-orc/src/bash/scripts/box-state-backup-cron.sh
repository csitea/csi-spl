#!/usr/bin/env bash
# box-state-backup-cron.sh - run do_spl_box_state_backup DRY_RUN=0 once a
# night, from the box user's crontab (owner t1 d80ed72c: a nightly copy of each
# box's box-only state, 30-day retention). Installed by do_install_box_crons as
# the manifest row box-state-backup (cnf/box-crons/box-crons.manifest), tagged
# `# csi-spl:box-cron:box-state-backup`.
#
# A cron job reads no profile: the PATH is set here (gcloud and yq live in
# /usr/local/bin) and the tools are checked before any work, so a missing one
# names itself in the log.
#
#   box-state-backup-cron.sh [--check-tools]
#
#   BOX_STATE_ENV   the env whose bucket takes the copy, default prd
#
# Exit: the action's own (0 uploaded, 3 the key scan refused the upload), 2
# usage or a refusal, 3 a tool this needs is not on the PATH.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
[ -n "${BOX_STATE_PATH_EXTRA:-}" ] && PATH="${BOX_STATE_PATH_EXTRA}:${PATH}"
export PATH
BOX_STATE_TOOLS="${BOX_STATE_TOOLS:-yq gcloud tar zstd rsync}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

check_tools() {
  local t missing=""
  for t in $BOX_STATE_TOOLS; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing} $t"
  done
  [ -z "$missing" ] && return 0
  say "FATAL these tools are not on the PATH:${missing} (PATH=$PATH; BOX_STATE_PATH_EXTRA adds a dir)"
  return 3
}

CHECK_TOOLS=0
case "${1:-}" in
  --check-tools) CHECK_TOOLS=1 ;;
  "") ;;
  *) echo "box-state-backup-cron: unknown argument: $1" >&2; exit 2 ;;
esac

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ORC="$(cd "$SELF/../../.." && pwd)"
check_tools || exit $?
if [ "$CHECK_TOOLS" = 1 ]; then say "OK every tool the run needs resolves: $BOX_STATE_TOOLS"; exit 0; fi
case "$ORC" in
  *-wt/*)
    [ "${BOX_STATE_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }
env_name="${BOX_STATE_ENV:-prd}"
case "$env_name" in dev|prd) ;; *) say "FATAL BOX_STATE_ENV: '$env_name' is not dev or prd"; exit 2 ;; esac

say "START box state backup ENV=$env_name"
( cd "$ORC" && env ENV="$env_name" DRY_RUN=0 ./run -a do_spl_box_state_backup ); rc=$?
say "STOP box state backup ENV=$env_name rc=$rc"
exit $rc

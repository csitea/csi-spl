#!/usr/bin/env bash
# msg-unreadable-cron.sh — run do_spl_msg_unreadable DELIVER=1 once a day, for
# each env in MSG_UNREADABLE_ENVS (default "prd dev"), from the box user's
# crontab. Installed by do_install_box_crons as the manifest row
# msg-unreadable (cnf/box-crons/box-crons.manifest), tagged
# `# csi-spl:box-cron:msg-unreadable`.
#
# A cron job reads no profile: the PATH is set here (psql, yq and gcloud live
# in /usr/local/bin; see desk-reconcile-cron.sh) and the tools are checked
# before any work, so a missing one names itself in the log.
#
#   msg-unreadable-cron.sh [--check-tools]
#
# Exit: 0 every env ran, 1 an env failed (the others still ran), 2 usage or a
# refusal, 3 a tool this needs is not on the PATH.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
[ -n "${MSG_UNREADABLE_PATH_EXTRA:-}" ] && PATH="${MSG_UNREADABLE_PATH_EXTRA}:${PATH}"
export PATH
MSG_UNREADABLE_TOOLS="${MSG_UNREADABLE_TOOLS:-yq psql gcloud}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

check_tools() {
  local t missing=""
  for t in $MSG_UNREADABLE_TOOLS; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing} $t"
  done
  [ -z "$missing" ] && return 0
  say "FATAL these tools are not on the PATH:${missing} (PATH=$PATH; MSG_UNREADABLE_PATH_EXTRA adds a dir)"
  return 3
}

CHECK_TOOLS=0
case "${1:-}" in
  --check-tools) CHECK_TOOLS=1 ;;
  "") ;;
  *) echo "msg-unreadable-cron: unknown argument: $1" >&2; exit 2 ;;
esac

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ORC="$(cd "$SELF/../../.." && pwd)"
check_tools || exit $?
if [ "$CHECK_TOOLS" = 1 ]; then say "OK every tool the run needs resolves: $MSG_UNREADABLE_TOOLS"; exit 0; fi
case "$ORC" in
  *-wt/*)
    [ "${MSG_UNREADABLE_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

rc=0
for env_name in ${MSG_UNREADABLE_ENVS:-prd dev}; do
  case "$env_name" in dev|prd) ;; *) say "FATAL MSG_UNREADABLE_ENVS: '$env_name' is not dev or prd"; exit 2 ;; esac
  say "START msg unreadable ENV=$env_name"
  ( cd "$ORC" && env ENV="$env_name" DELIVER=1 ./run -a do_spl_msg_unreadable ); r=$?
  say "STOP msg unreadable ENV=$env_name rc=$r"
  [ "$r" = 0 ] || rc=1
done
exit $rc

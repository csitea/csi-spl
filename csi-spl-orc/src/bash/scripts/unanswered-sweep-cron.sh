#!/usr/bin/env bash
# unanswered-sweep-cron.sh — run do_spl_unanswered_sweep DELIVER=1 from the
# box user's crontab (SPEC-spool-fleet-roles.md 3.2). Installed by
# do_spl_unanswered_sweep_install_cron as ONE line tagged
# `# csi-spl:unanswered-sweep` (prd) / `# csi-spl:unanswered-sweep-<env>`.
#
# A cron job reads no profile: the PATH is set here (psql, yq and gcloud live
# in /usr/local/bin on this box; see desk-reconcile-cron.sh for the measured
# failure) and the tools are checked before any work, so a missing one names
# itself in the log.
#
#   unanswered-sweep-cron.sh [--check-tools]
#
# Exit: 0 swept (or another sweep held the lock), 1 the sweep failed, 2 usage
# or a refusal, 3 a tool this needs is not on the PATH.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
[ -n "${SWEEP_CRON_PATH_EXTRA:-}" ] && PATH="${SWEEP_CRON_PATH_EXTRA}:${PATH}"
export PATH
SWEEP_CRON_TOOLS="${SWEEP_CRON_TOOLS:-python3 yq psql gcloud flock}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

check_tools() {
  local t missing=""
  for t in $SWEEP_CRON_TOOLS; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing} $t"
  done
  [ -z "$missing" ] && return 0
  say "FATAL these tools are not on the PATH:${missing} (PATH=$PATH; SWEEP_CRON_PATH_EXTRA adds a dir)"
  return 3
}

CHECK_TOOLS=0
case "${1:-}" in
  --check-tools) CHECK_TOOLS=1 ;;
  "") ;;
  *) echo "unanswered-sweep-cron: unknown argument: $1" >&2; exit 2 ;;
esac

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ORC="$(cd "$SELF/../../.." && pwd)"
check_tools || exit $?
if [ "$CHECK_TOOLS" = 1 ]; then say "OK every tool the sweep needs resolves: $SWEEP_CRON_TOOLS"; exit 0; fi
case "$ORC" in
  *-wt/*)
    [ "${SWEEP_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

say "START unanswered sweep ENV=${ENV:-prd}"
( cd "$ORC" && env ENV="${ENV:-prd}" DELIVER=1 ./run -a do_spl_unanswered_sweep ); rc=$?
say "STOP unanswered sweep rc=$rc"
[ "$rc" = 0 ] || exit 1

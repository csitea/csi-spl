#!/usr/bin/env bash
# agent-boot-restore-cron.sh — run do_spl_agent_boot_restore DRY_RUN=0 from
# the box user's crontab at @reboot: every agent the reboot killed comes back
# in its own session and worktree, AS THE AGENT USER (owner rule 2026-10-01).
# Installed by do_spl_agent_boot_restore_install_cron as ONE line tagged
# `# csi-spl:agent-boot-restore`. A box whose boot job already calls
# do_spl_agent_identity_restore (a box engine's claude-sessions boot) does not
# need it.
#
# A cron job reads no profile: the PATH is set here and the tools are checked
# before any work, so a missing one names itself in the log.
#
#   agent-boot-restore-cron.sh [--check-tools]
#
# Exit: 0 restored (or nothing to restore); 1 the restore failed or an agent
# runs as the box user (the action left its marker); 2 usage or a refusal; 3 a
# tool this needs is not on the PATH.
set -uo pipefail
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
[ -n "${BOOT_RESTORE_PATH_EXTRA:-}" ] && PATH="${BOOT_RESTORE_PATH_EXTRA}:${PATH}"
export PATH
BOOT_RESTORE_TOOLS="${BOOT_RESTORE_TOOLS:-python3 tmux git ps sudo}"

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

check_tools() {
  local t missing=""
  for t in $BOOT_RESTORE_TOOLS; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing} $t"
  done
  [ -z "$missing" ] && return 0
  say "FATAL these tools are not on the PATH:${missing} (PATH=$PATH; BOOT_RESTORE_PATH_EXTRA adds a dir)"
  return 3
}

CHECK_TOOLS=0
case "${1:-}" in
  --check-tools) CHECK_TOOLS=1 ;;
  "") ;;
  *) echo "agent-boot-restore-cron: unknown argument: $1" >&2; exit 2 ;;
esac

SELF="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
ORC="$(cd "$SELF/../../.." && pwd)"
check_tools || exit $?
if [ "$CHECK_TOOLS" = 1 ]; then say "OK every tool the boot restore needs resolves: $BOOT_RESTORE_TOOLS"; exit 0; fi
case "$ORC" in
  *-wt/*)
    [ "${BOOT_RESTORE_ALLOW_WORKTREE:-0}" = 1 ] ||
      { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; exit 2; } ;;
esac
[ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; exit 2; }

say "START agent boot restore"
( cd "$ORC" && env DRY_RUN=0 ./run -a do_spl_agent_boot_restore ); rc=$?
say "STOP agent boot restore rc=$rc"
[ "$rc" = 0 ] || exit 1

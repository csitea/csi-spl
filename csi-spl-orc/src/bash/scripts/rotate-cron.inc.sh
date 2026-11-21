#!/usr/bin/env bash
# rotate-cron.inc.sh — the preamble the rotation cron wrappers share
# (orch-rotate-cron.sh, dispatch-rotate-cron.sh); sourced, never run. A cron
# job reads no profile, so the PATH is set here; check_tools checks the
# caller's ROTATE_CRON_TOOLS; rotate_cron_orc sets ORC to the shared checkout's
# csi-spl-orc and refuses an agent worktree or a missing ./run (returns 2).
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"
[ -n "${ROTATE_CRON_PATH_EXTRA:-}" ] && PATH="${ROTATE_CRON_PATH_EXTRA}:${PATH}"
export PATH

say() { printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"; }

check_tools() {
  local t missing=""
  for t in $ROTATE_CRON_TOOLS; do
    command -v "$t" >/dev/null 2>&1 || missing="${missing} $t"
  done
  [ -z "$missing" ] && return 0
  say "FATAL these tools are not on the PATH:${missing} (PATH=$PATH; ROTATE_CRON_PATH_EXTRA adds a dir)"
  return 3
}

rotate_cron_orc() {
  local self
  self="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
  ORC="$(cd "$self/../../.." && pwd)"
  case "$ORC" in
    *-wt/*)
      [ "${ROTATE_ALLOW_WORKTREE:-0}" = 1 ] ||
        { say "FATAL $ORC is in an agent worktree - install the cron against the shared checkout"; return 2; } ;;
  esac
  [ -x "$ORC/run" ] || { say "FATAL $ORC/run not found or not executable"; return 2; }
}

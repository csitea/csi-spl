#!/usr/bin/env bash
#------------------------------------------------------------------------------
# spool-install step Y11: the pkill / killall guard for the agent user.
#
#   spool_install_kill_guard <bin-dir> <dry 0|1> <fleet 0|1>
#
# Copies assets/kill-guard/kill-guard.sh to <bin-dir>/pkill and
# <bin-dir>/killall (install.sh passes ~/.local/bin, which the agent user's
# login shells put ahead of /usr/bin). They refuse `pkill -f` / `--full` and
# every `killall` (exit 2, one line) and pass every other form to the real
# binary: a pattern kill matches every agent seat's argv.
#
# Only on a --fleet install, and only when this user IS the agent user:
# SPOOL_AGENT_USER, else the SPOOL_AGENT_USER of the box config
# (SPOOL_BOX_ENV, default $SPOOL_ROOT/box.env, SPOOL_ROOT default
# /var/spool-hub). An unresolved agent user skips the step and says so: the
# human's own shell keeps the real pkill.
# Idempotent: a current copy is not rewritten. A file in the way that does not
# carry the kill-guard marker is left alone (return 7).
# SPOOL_INSTALL_KILL_GUARD=0 skips the step.
#------------------------------------------------------------------------------
spool_install_kill_guard() {
  local bin="$1" dry="${2:-0}" fleet="${3:-0}" here src agent_user f n dst
  local mark="# spool kill-guard, written by spool-install"
  if [ "${SPOOL_INSTALL_KILL_GUARD:-1}" = 0 ]; then
    echo "spool-install: kill-guard: skipped (SPOOL_INSTALL_KILL_GUARD=0)" >&2
    return 0
  fi
  [ "$fleet" = 1 ] || return 0
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  src="$here/../assets/kill-guard/kill-guard.sh"
  agent_user="${SPOOL_AGENT_USER:-}"
  f="${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}"
  if [ -z "$agent_user" ] && [ -r "$f" ]; then
    agent_user="$(sed -n 's/^SPOOL_AGENT_USER=//p' "$f" | tail -1 | tr -d "\"'\r")"
  fi
  if [ -z "$agent_user" ]; then
    echo "spool-install: kill-guard: skipped (no SPOOL_AGENT_USER, none in $f)" >&2
    return 0
  fi
  if [ "$(id -un)" != "$agent_user" ]; then
    echo "spool-install: kill-guard: skipped ($(id -un) is not the agent user $agent_user)" >&2
    return 0
  fi
  for n in pkill killall; do
    dst="$bin/$n"
    if [ -e "$dst" ] && ! grep -qF "$mark" "$dst" 2>/dev/null; then
      echo "spool-install: kill-guard: $dst exists and is not ours: left alone" >&2
      return 7
    fi
    if [ -e "$dst" ] && cmp -s "$src" "$dst"; then
      echo "spool-install: kill-guard: $dst already current" >&2
      continue
    fi
    if [ "$dry" = 1 ]; then echo "would: install the kill-guard as $dst"; continue; fi
    mkdir -p "$bin" && cp "$src" "$dst.tmp" && chmod 755 "$dst.tmp" && mv -f "$dst.tmp" "$dst" || return 7
    echo "spool-install: kill-guard: $dst" >&2
  done
}

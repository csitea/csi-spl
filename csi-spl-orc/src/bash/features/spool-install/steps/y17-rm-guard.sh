#!/usr/bin/env bash
#------------------------------------------------------------------------------
# spool-install step Y17: the rm guard for the agent user (SPL-2474).
#
#   spool_install_rm_guard <bin-dir> <dry 0|1> <fleet 0|1>
#
# Copies assets/rm-guard/rm-guard.sh to <bin-dir>/rm (install.sh passes
# ~/.local/bin, which every agent seat's PATH puts ahead of /usr/bin: claude,
# grok, agy, mistral and qwen alike). It refuses a recursive rm of /, a
# top-level dir, a home root or a direct child of one (exit 2, one line) and
# passes every other call to the real rm: on 2026-10-17 an unset variable
# turned `rm -rf "$PROC"/*` into `rm -rf /*` in an agent's tool shell.
#
# Only on a --fleet install, and only when this user IS the agent user (the
# kill-guard rule, y11-kill-guard.sh): the human's own shell keeps the real rm.
# Idempotent: a current copy is not rewritten. A file in the way that does not
# carry the rm-guard marker is left alone (return 7).
# SPOOL_INSTALL_RM_GUARD=0 skips the step.
#------------------------------------------------------------------------------
spool_install_rm_guard() {
  local bin="$1" dry="${2:-0}" fleet="${3:-0}" here src agent_user f dst
  local mark="# spool rm-guard, written by spool-install"
  if [ "${SPOOL_INSTALL_RM_GUARD:-1}" = 0 ]; then
    echo "spool-install: rm-guard: skipped (SPOOL_INSTALL_RM_GUARD=0)" >&2
    return 0
  fi
  [ "$fleet" = 1 ] || return 0
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  src="$here/../assets/rm-guard/rm-guard.sh"
  agent_user="${SPOOL_AGENT_USER:-}"
  f="${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}"
  if [ -z "$agent_user" ] && [ -r "$f" ]; then
    agent_user="$(sed -n 's/^SPOOL_AGENT_USER=//p' "$f" | tail -1 | tr -d "\"'\r")"
  fi
  if [ -z "$agent_user" ]; then
    echo "spool-install: rm-guard: skipped (no SPOOL_AGENT_USER, none in $f)" >&2
    return 0
  fi
  if [ "$(id -un)" != "$agent_user" ]; then
    echo "spool-install: rm-guard: skipped ($(id -un) is not the agent user $agent_user)" >&2
    return 0
  fi
  dst="$bin/rm"
  if [ -e "$dst" ] && ! grep -qF "$mark" "$dst" 2>/dev/null; then
    echo "spool-install: rm-guard: $dst exists and is not ours: left alone" >&2
    return 7
  fi
  if [ -e "$dst" ] && cmp -s "$src" "$dst"; then
    echo "spool-install: rm-guard: $dst already current" >&2
    return 0
  fi
  if [ "$dry" = 1 ]; then echo "would: install the rm-guard as $dst"; return 0; fi
  # the copy is renamed into place with mv: rm is never run on the target
  mkdir -p "$bin" && cp "$src" "$dst.tmp" && chmod 755 "$dst.tmp" && mv -f "$dst.tmp" "$dst" || return 7
  echo "spool-install: rm-guard: $dst" >&2
}

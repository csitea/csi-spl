#!/usr/bin/env bash
#------------------------------------------------------------------------------
# spool-install step Y16: an agent's git never opens a pager (SPL-2432).
#
#   spool_install_git_pager_off <home> <dry 0|1>
#
# Sets core.pager=cat in the global git config of <home> (git config --global
# with HOME=<home>: ~/.gitconfig, or ~/.config/git/config when only that one
# exists). Why: agy's shell tool has a tty, so `git log` there starts less and
# waits for a key nobody presses (a-271 hung 38 min, a-235 too, 2026-10-17).
# Why core.pager=cat and not pager.<cmd>=false: one key covers every command
# that pages (log, show, diff, branch, tag, grep, ...), git runs no pager at
# all for "cat", and it wins over $PAGER; pager.<cmd> needs a key per command
# and misses the next one. A launcher GIT_PAGER does not survive sudo's
# env_reset, so it lives in the user's git config, not in the launcher env.
# Idempotent: core.pager already "cat" says current and writes nothing. A
# different core.pager someone set is kept and named
# (SPOOL_INSTALL_GIT_PAGER_FORCE=1 replaces it).
# SPOOL_INSTALL_GIT_PAGER=0 skips the step.
#------------------------------------------------------------------------------
_y16_git() { env -u XDG_CONFIG_HOME -u GIT_CONFIG_GLOBAL HOME="$1" git config --global "${@:2}"; }

spool_install_git_pager_off() {
  local home="$1" dry="${2:-0}" cur
  if [ "${SPOOL_INSTALL_GIT_PAGER:-1}" = 0 ]; then
    echo "spool-install: git pager: skipped (SPOOL_INSTALL_GIT_PAGER=0)" >&2
    return 0
  fi
  [ -d "$home" ] || { echo "spool-install: git pager: no home $home" >&2; return 7; }
  command -v git >/dev/null 2>&1 || { echo "spool-install: git pager: no git on PATH" >&2; return 7; }
  cur="$(_y16_git "$home" --get core.pager 2>/dev/null)"
  if [ "$cur" = cat ]; then
    echo "spool-install: git pager: $home already current (core.pager=cat)" >&2
    return 0
  fi
  if [ -n "$cur" ] && [ "${SPOOL_INSTALL_GIT_PAGER_FORCE:-0}" != 1 ]; then
    echo "spool-install: git pager: WARN $home keeps core.pager='$cur' set by hand: git there still pages (SPOOL_INSTALL_GIT_PAGER_FORCE=1 replaces it)" >&2
    return 0
  fi
  if [ "$dry" = 1 ]; then
    echo "would: git config --global core.pager cat for $home${cur:+ (was '$cur')}"
    return 0
  fi
  _y16_git "$home" core.pager cat || return 7
  echo "spool-install: git pager: core.pager=cat for $home${cur:+ (was '$cur')}" >&2
}

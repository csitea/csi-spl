#!/usr/bin/env bash
#------------------------------------------------------------------------------
# spool-install step Y19: no clear-text git credential store (SPL-3761).
#
#   spool_install_git_credential_store <dry 0|1>
#
# A global credential.helper=store makes git write every token it is given in
# clear text to ~/.git-credentials: on 2026-10-26 a read-only HTTPS clone of a
# private repo left a GitHub token there on one box, and no repo code sets the
# helper, so an ad hoc command can bring it back anywhere. For this user
# ($HOME), the agent user and the box user (SPOOL_AGENT_USER /
# SPOOL_BOX_USER, else the box config: SPOOL_BOX_ENV, default
# $SPOOL_ROOT/box.env; their homes from passwd) the step:
#   - removes every credential.helper (also credential.<url>.helper) whose
#     value is `store` from ~/.gitconfig and ~/.config/git/config, after a
#     backup <file>.bak-spool-install.<UTC>; any other helper is kept
#   - truncates a non-empty ~/.git-credentials (and ~/.config/git/credentials)
#     to 0 bytes; it is never read, copied or printed
# One line per change. A file this user cannot write is named (WARN), never
# reached with sudo: re-run install.sh --fleet as its owner. The system git
# config is left alone (do_spl_agent_settings_check reports it). A sandbox
# run (HOME is not this user's passwd home: the tests) touches $HOME only.
# SPOOL_INSTALL_GIT_CRED_HOMES - the other users' homes instead of passwd (tests)
# SPOOL_INSTALL_GIT_CRED=0 skips the step.
#------------------------------------------------------------------------------
_Y19_KEY='^credential\.(.*\.)?helper$'
_Y19_STORE='^store([[:space:]]|$)'

# _y19_box_var NAME: NAME from the environment, else from the box config
_y19_box_var() {
  local f="${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}"
  if [ -n "${!1:-}" ]; then printf '%s' "${!1}"; return 0; fi
  [ -r "$f" ] && sed -n "s/^$1=//p" "$f" | tail -1 | tr -d "\"'\r"
}

# _y19_homes: $HOME, then the agent user's and the box user's homes
_y19_homes() {
  local u me h
  me="$(id -un)"
  printf '%s\n' "$HOME"
  if [ -n "${SPOOL_INSTALL_GIT_CRED_HOMES:-}" ]; then
    tr ' ' '\n' <<<"$SPOOL_INSTALL_GIT_CRED_HOMES"
    return 0
  fi
  if [ "$HOME" != "$(getent passwd "$me" 2>/dev/null | cut -d: -f6)" ]; then
    echo "spool-install: git credentials: HOME is not $me's passwd home: the other users' homes are left alone" >&2
    return 0
  fi
  for u in "$(_y19_box_var SPOOL_AGENT_USER)" "$(_y19_box_var SPOOL_BOX_USER)"; do
    [ -n "$u" ] && [ "$u" != "$me" ] || continue
    h="$(getent passwd "$u" 2>/dev/null | cut -d: -f6)"
    [ -n "$h" ] && printf '%s\n' "$h"
  done
  return 0
}

# _y19_config FILE DRY: drop the store helpers of one git config file
_y19_config() {
  local f="$1" dry="$2" keys k bak
  [ -r "$f" ] || return 0
  keys="$(git config --file "$f" --get-regexp "$_Y19_KEY" 2>/dev/null | awk '$2 == "store" { print $1 }' | sort -u)"
  [ -n "$keys" ] || return 0
  if [ ! -w "$f" ]; then
    echo "spool-install: git credentials: WARN $f sets credential.helper=store and $(id -un) cannot write it: re-run install.sh --fleet as its owner" >&2
    return 0
  fi
  if [ "$dry" = 1 ]; then
    echo "would: back up $f and remove its credential.helper=store"
    return 0
  fi
  bak="$f.bak-spool-install.$(date -u +%Y%m%dT%H%M%SZ)"
  cp -p "$f" "$bak" || return 7
  for k in $keys; do git config --file "$f" --unset-all "$k" "$_Y19_STORE" || return 7; done
  echo "spool-install: git credentials: removed credential.helper=store from $f (backup $bak)" >&2
}

# _y19_store FILE DRY: empty a non-empty credential store, never reading it
_y19_store() {
  local f="$1" dry="$2"
  [ -s "$f" ] || return 0
  if [ ! -w "$f" ]; then
    echo "spool-install: git credentials: WARN $f is not empty and $(id -un) cannot write it: re-run install.sh --fleet as its owner" >&2
    return 0
  fi
  if [ "$dry" = 1 ]; then
    echo "would: truncate $f to 0 bytes"
    return 0
  fi
  : >"$f" || return 7
  echo "spool-install: git credentials: truncated $f to 0 bytes (clear-text git credentials; not read, not printed)" >&2
}

spool_install_git_credential_store() {
  local dry="${1:-0}" h
  if [ "${SPOOL_INSTALL_GIT_CRED:-1}" = 0 ]; then
    echo "spool-install: git credentials: skipped (SPOOL_INSTALL_GIT_CRED=0)" >&2
    return 0
  fi
  command -v git >/dev/null 2>&1 || { echo "spool-install: git credentials: no git on PATH" >&2; return 7; }
  while IFS= read -r h; do
    [ -n "$h" ] && [ -d "$h" ] || continue
    _y19_config "$h/.gitconfig" "$dry" || return 7
    _y19_config "$h/.config/git/config" "$dry" || return 7
    _y19_store "$h/.git-credentials" "$dry" || return 7
    _y19_store "$h/.config/git/credentials" "$dry" || return 7
  done < <(_y19_homes | awk 'NF && !seen[$0]++')
  return 0
}

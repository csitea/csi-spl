#!/usr/bin/env bash
# directive-env.inc.sh — the directive scripts' box config (sourced, not executed).
#
# The pin (DIRECTIVE_FPR) and the other DIRECTIVE_* knobs live in the spool's
# box config, ${SPOOL_BOX_ENV:-$SPOOL_ROOT/box.env}, which an interactive shell
# never sources: without this the documented command fails with "set
# DIRECTIVE_FPR" on a box where it IS configured. The box tag comes from the
# same file (SPOOL_BOX_TAG).
#
# PARSE-ONLY, for every user: the file is read as KEY=VALUE lines (an optional
# leading "export " is allowed) and never sourced, so root, which owns the
# keyring and the nonce ledger, can read it without running anything in it.
# A variable that is already set wins, so DIRECTIVE_FPR=... on the command line
# still overrides the file.

directive_env_load() {
  local f="${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}" k v
  [ -r "$f" ] || return 0
  while IFS='=' read -r k v || [ -n "$k" ]; do
    k="${k#export }"; k="${k// /}"
    case "$k" in DIRECTIVE_*|SPOOL_BOX_TAG) ;; *) continue ;; esac
    [[ "$k" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
    [ -n "${!k:-}" ] && continue
    v="${v%$'\r'}"; v="${v#\"}"; v="${v%\"}"; v="${v#\'}"; v="${v%\'}"
    printf -v "$k" '%s' "$v"
  done <"$f"
}

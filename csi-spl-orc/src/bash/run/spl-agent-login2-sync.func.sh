#!/bin/bash
#------------------------------------------------------------------------------
# @description The second Claude login's sync (SPL-2943; owner HUM-10 t1
# @description 678d29e2, msg abcbed75): the backup account's Claude config
# @description (credential, session file, settings) is the box user's own main
# @description Claude config folder (owner choice B, msg d168e017: the owner's login and
# @description the backup account are the same), renewed by its own use;
# @description this action only reads it and copies it, one
# @description way, into the agent user's second config folder, the one the
# @description claude2 vendor step starts claude with (CLAUDE_CONFIG_DIR,
# @description do_spl_role_failover). Run by the box cron (row login2-sync of
# @description cnf/box-crons/box-crons.manifest).
# @description Guards (c-002 430b912f):
# @description   1. the source is ONE setting, LOGIN2_SYNC_SRC (else
# @description      SPOOL_LOGIN2_SRC in box.env); unset or missing = a WARN
# @description      and nothing copied; the box user's own main config folder
# @description      is allowed (owner B); never the agent user's main
# @description      ~/.claude, and never the destination itself.
# @description   2. newer only: copied only when the source credential's
# @description      claudeAiOauth.expiresAt is later than the destination's
# @description      (none there = 0); never the other way.
# @description   3. every file lands as the agent user, mode 600 (folder 700),
# @description      via a temp file in the same folder and mv; the old
# @description      credential kept as .credentials.json.bak-login2-<UTC>.
# @description Prints only "copied, expires <UTC>" or why not: never content.
# @description Dry run unless DRY_RUN=0.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param LOGIN2_SYNC_SRC (optional) - the backup config folder, the box user's own Claude config folder (default: SPOOL_LOGIN2_SRC of box.env; none = WARN, no-op)
# @param CLAUDE2_CONFIG_DIR (optional) - the agent user's second config folder, default <agent home>/.claude-2 (the same default as do_spl_role_failover)
# @param SPOOL_AGENT_USER (optional) - default SPOOL_AGENT_USER of box.env, else this user
# @param LOGIN2_AGENT_HOME (optional, tests) - the agent user's home (default: from getent)
# @param LOGIN2_SUDO (optional, tests) - the prefix that runs as the agent user ("" = none)
# @example ./run -a do_spl_agent_login2_sync
# @example DRY_RUN=0 ./run -a do_spl_agent_login2_sync
#------------------------------------------------------------------------------
declare -F _spool_box_env_load >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../features/spawn-agents/lib/spool-env.inc.sh"

# the files of a Claude config folder the copy carries; the credential first
L2_FILES=(.credentials.json .claude.json settings.json)

do_spl_agent_login2_sync() {
  local dry="${DRY_RUN:-1}" src dst user home sexp dexp
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  user="${SPOOL_AGENT_USER:-}"
  [[ -n "$user" ]] || user="$(SPOOL_AGENT_USER=''; _spool_box_env_load; printf '%s' "${SPOOL_AGENT_USER:-}")"
  [[ -n "$user" ]] || user="$(id -un)"
  home="${LOGIN2_AGENT_HOME:-$(getent passwd "$user" | cut -d: -f6)}"
  [[ -n "$home" ]] || { do_log "FATAL no home for the agent user $user"; return 1; }
  if [[ -n "${LOGIN2_SUDO+x}" ]]; then L2_SU="$LOGIN2_SUDO"
  elif [[ "$user" == "$(id -un)" ]]; then L2_SU=""
  else L2_SU="sudo -n -u $user"; fi
  src="$(_l2_src)"
  dst="${CLAUDE2_CONFIG_DIR:-$home/.claude-2}"
  [[ -n "$src" ]] || { echo "login2-sync: WARN no source set (LOGIN2_SYNC_SRC, or SPOOL_LOGIN2_SRC in box.env): nothing copied"; return 0; }
  _l2_refuse "$src" "$dst" "$home" || return 2
  [[ -s "$src/.credentials.json" ]] || { echo "login2-sync: WARN no credential in the source folder $src: nothing copied"; return 0; }
  jq -e '.claudeAiOauth.refreshToken | strings | length > 0' "$src/.credentials.json" >/dev/null 2>&1 ||
    { echo "login2-sync: WARN the source credential in $src is no Claude login: nothing copied"; return 0; }
  sexp="$(_l2_exp cat "$src/.credentials.json")"
  dexp="$(_l2_exp _l2_as cat "$dst/.credentials.json")"
  if (( sexp <= dexp )); then
    echo "login2-sync: up to date, $dst expires $(_l2_utc "$dexp") (source $(_l2_utc "$sexp")): nothing copied"; return 0
  fi
  if [[ "$dry" == 1 ]]; then
    echo "login2-sync: PLAN copy $src -> $dst, expires $(_l2_utc "$sexp") (now $(_l2_utc "$dexp")) (DRY_RUN)"; return 0
  fi
  _l2_copy "$src" "$dst" || { echo "login2-sync: FAILED the copy into $dst"; return 1; }
  echo "login2-sync: copied, expires $(_l2_utc "$sexp")"
}

# The source folder: LOGIN2_SYNC_SRC, else SPOOL_LOGIN2_SRC of box.env.
_l2_src() {
  local s="${LOGIN2_SYNC_SRC:-}" env="${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}"
  [[ -n "$s" || ! -r "$env" ]] || s="$(sed -n 's/^SPOOL_LOGIN2_SRC=\(\/[^[:space:]]*\)$/\1/p' "$env" | tail -1)"
  printf '%s' "${s%/}"
}

# Refuse a source that is the agent user's main login or the destination
# (guard 1). The box user's own main folder is allowed (owner B, d168e017).
_l2_refuse() {
  local s d m
  s="$(readlink -m "$1")"; d="$(readlink -m "$2")"
  for m in "$(readlink -m "$3/.claude")" "$d"; do
    [[ "$s" == "$m" ]] && { echo "login2-sync: REFUSED the source $1 is the agent user's main login or the destination itself"; return 1; }
  done
  [[ "$d" == "$(readlink -m "$3/.claude")" ]] && { echo "login2-sync: REFUSED the destination $2 is the agent user's main login"; return 1; }
  return 0
}

# shellcheck disable=SC2086  # L2_SU is a command prefix, split on purpose
_l2_as() { $L2_SU "$@"; }

# expiresAt (ms) of the credential CMD... prints; 0 when none or unreadable.
_l2_exp() {
  local e
  e="$("$@" 2>/dev/null | jq -r '.claudeAiOauth.expiresAt // 0' 2>/dev/null)"
  [[ "$e" =~ ^[0-9]+$ ]] || e=0
  echo "$e"
}

_l2_utc() { if (( $1 > 0 )); then date -u -d "@$(( $1 / 1000 ))" +%Y-%m-%dT%H:%M:%SZ; else echo none; fi; }

# Each present file of the source, as the agent user: temp in DST + mv, 600.
_l2_copy() {
  local src="$1" dst="$2" f tmp ts
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  _l2_as mkdir -p "$dst" && _l2_as chmod 700 "$dst" || return 1
  if _l2_as test -e "$dst/.credentials.json"; then
    _l2_as cp -p "$dst/.credentials.json" "$dst/.credentials.json.bak-login2-$ts" || return 1
  fi
  for f in "${L2_FILES[@]}"; do
    [[ -s "$src/$f" ]] || continue
    tmp="$(_l2_as mktemp "$dst/.login2-in.XXXXXX")" || return 1
    # shellcheck disable=SC2016  # expanded by the inner shell
    if ! _l2_as bash -c 'umask 077; cat > "$1"' _ "$tmp" < "$src/$f" || ! _l2_as chmod 600 "$tmp" || ! _l2_as mv -f "$tmp" "$dst/$f"; then
      _l2_as rm -f "$tmp"; return 1
    fi
  done
  # shellcheck disable=SC2016
  _l2_as bash -c 'ls -1 "$1".bak-login2-* 2>/dev/null | sort -r | tail -n +6 | xargs -r rm -f' _ "$dst/.credentials.json"
}

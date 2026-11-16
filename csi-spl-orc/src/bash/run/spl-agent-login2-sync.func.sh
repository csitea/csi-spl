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
# @description PEER source (SPL-5695, owner HUM-10 t1 64ca0e0c msg 5ff9dea1:
# @description "one second folder: it holds the other box's account for both
# @description uses"): LOGIN2_SYNC_SRC=peer:<tag>, else SPOOL_LOGIN2_PEER=
# @description <tag>=<ssh dest> of box.env (it wins over SPOOL_LOGIN2_SRC).
# @description This box drives both directions over its ssh path (the peer
# @description may not reach it): the peer's main login -> the second folder
# @description here, and this box's main login -> the peer's second folder
# @description (agent-login-cred.sh slot 2). Per direction, by account label
# @description (acct-<8 hex>, never an email or a token): another label in
# @description the second folder is replaced at once (a stale account); the
# @description same label copies the newer credential, and a newer second
# @description folder copy that probes ok goes BACK into the lender's main
# @description login (newest wins within one label). A main login is never
# @description written with another label. The .claude.json of a second
# @description folder gets only oauthAccount and hasCompletedOnboarding.
# @description REFUSED (exit 2) while the same tag is in SPOOL_LOGIN_PEERS:
# @description that main-to-main push would overwrite the peer's own account
# @description (the owner's step 0 empties it first).
# @description Dry run unless DRY_RUN=0.
# @param DRY_RUN (optional) - 1 (default) or 0
# @param LOGIN2_SYNC_SRC (optional) - the backup config folder, the box user's own Claude config folder, or peer:<tag> (default: SPOOL_LOGIN2_PEER of box.env as peer:<tag>, else SPOOL_LOGIN2_SRC; none = WARN, no-op)
# @param LOGIN2_PEER_DEST (optional) - the ssh destination of the peer, default the <ssh dest> of SPOOL_LOGIN2_PEER in box.env
# @param LOGIN2_PEER_CMD (optional, tests) - runs a credential op on the peer in place of ssh: called with <dest> <op> <slot>
# @param LOGIN2_CRED_CMD (optional, tests) - the credential helper script here, default agent-login-cred.sh
# @param CLAUDE2_CONFIG_DIR (optional) - the agent user's second config folder, default <agent home>/.claude-2 (the same default as do_spl_role_failover)
# @param SPOOL_AGENT_USER (optional) - default SPOOL_AGENT_USER of box.env, else this user
# @param LOGIN2_AGENT_HOME (optional, tests) - the agent user's home (default: from getent)
# @param LOGIN2_SUDO (optional, tests) - the prefix that runs as the agent user ("" = none)
# @example ./run -a do_spl_agent_login2_sync
# @example DRY_RUN=0 ./run -a do_spl_agent_login2_sync
#------------------------------------------------------------------------------
# _l2_deps: _spool_box_env_load, sourced on the first call, not at source
# time, so the ./run loader keeps this file lazy (spec 027, p8-01)
_l2_deps() {
  declare -F _spool_box_env_load >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/../features/spawn-agents/lib/spool-env.inc.sh"
}

do_spl_agent_login2_sync() {
  local dry="${DRY_RUN:-1}" src dst user home sexp dexp
  _l2_deps
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  user="${SPOOL_AGENT_USER:-}"
  [[ -n "$user" ]] || user="$(SPOOL_AGENT_USER=''; _spool_box_env_load; printf '%s' "${SPOOL_AGENT_USER:-}")"
  [[ -n "$user" ]] || user="$(id -un)"
  home="${LOGIN2_AGENT_HOME:-$(getent passwd "$user" | cut -d: -f6)}"
  [[ -n "$home" ]] || { do_log "FATAL no home for the agent user $user"; return 1; }
  if [[ -n "${LOGIN2_SUDO+x}" ]]; then L2_SU="$LOGIN2_SUDO"
  elif [[ "$user" == "$(id -un)" ]]; then L2_SU=""
  else L2_SU="sudo -n -u $user"; fi
  L2_USER="$user"; L2_HOME="$home"
  src="$(_l2_src)"
  dst="${CLAUDE2_CONFIG_DIR:-$home/.claude-2}"
  [[ -n "$src" ]] || { echo "login2-sync: WARN no source set (LOGIN2_SYNC_SRC, or SPOOL_LOGIN2_PEER / SPOOL_LOGIN2_SRC in box.env): nothing copied"; return 0; }
  [[ "$src" == peer:* ]] && { _l2_peer_sync "${src#peer:}" "$dst" "$dry"; return; }
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

# The source: LOGIN2_SYNC_SRC, else peer:<tag> of SPOOL_LOGIN2_PEER, else
# SPOOL_LOGIN2_SRC of box.env.
_l2_src() {
  local s="${LOGIN2_SYNC_SRC:-}" env
  env="$(_l2_box_env)"
  [[ -n "$s" || ! -r "$env" ]] || s="$(_l2_peer_entry | sed -n 's/^\([^=]*\)=.*/peer:\1/p')"
  [[ -n "$s" || ! -r "$env" ]] || s="$(sed -n 's/^SPOOL_LOGIN2_SRC=\(\/[^[:space:]]*\)$/\1/p' "$env" | tail -1)"
  printf '%s' "${s%/}"
}

_l2_box_env() { echo "${SPOOL_BOX_ENV:-${SPOOL_ROOT:-/var/spool-hub}/box.env}"; }

# box.env's SPOOL_LOGIN2_PEER, "<tag>=<ssh dest>", or nothing.
_l2_peer_entry() {
  sed -n 's/^SPOOL_LOGIN2_PEER=//p' "$(_l2_box_env)" 2>/dev/null | tail -1 | tr -d "\"' "
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
  # the files of a Claude config folder the copy carries; the credential first
  local L2_FILES=(.credentials.json .claude.json settings.json)
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

# The peer source (SPL-5695): both directions, each by account label.
_l2_peer_sync() {
  local tag="$1" dst="$2" dry="$3" dest
  [[ "$tag" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { echo "login2-sync: REFUSED the peer tag '$tag' is no box tag"; return 2; }
  dest="${LOGIN2_PEER_DEST:-$(_l2_peer_entry | sed -n "s/^$tag=//p")}"
  [[ -n "$dest" ]] || { echo "login2-sync: WARN no ssh destination for peer $tag (SPOOL_LOGIN2_PEER=$tag=<dest> in box.env): nothing copied"; return 0; }
  if _l2_main_peers | grep -qx "$tag"; then
    echo "login2-sync: REFUSED peer $tag is also in SPOOL_LOGIN_PEERS: the main-to-main push would overwrite its own account (empty it first, the owner's step 0)"; return 2
  fi
  L2_DEST="$dest"; L2_DIR2="$dst"; L2_DRY="$dry"; L2_RC=0
  _l2_dir "$tag -> here" peer here
  _l2_dir "here -> $tag" here peer
  return "$L2_RC"
}

# The tags of SPOOL_LOGIN_PEERS (LOGIN_PEERS overrides), one per line.
_l2_main_peers() {
  local p
  if [[ -n "${LOGIN_PEERS+x}" ]]; then p="$LOGIN_PEERS"
  else p="$(sed -n 's/^SPOOL_LOGIN_PEERS=//p' "$(_l2_box_env)" 2>/dev/null | tail -1 | tr -d "\"'")"; fi
  tr ', ' '\n\n' <<<"$p" | sed -n 's/^\([a-z0-9][a-z0-9-]*\)=.*/\1/p'
}

# One credential op: _l2_at here|peer OP SLOT. Here runs the helper with the
# second folder of this action; the peer runs it over ssh (its own default).
_l2_at() {
  local where="$1" op="$2" slot="$3" script
  if [[ "$where" == here ]]; then
    local helper="${LOGIN2_CRED_CMD:-$PROJ_PATH/src/bash/scripts/agent-login-cred.sh}"
    LOGIN_AGENT_USER="$L2_USER" LOGIN_AGENT_HOME="$L2_HOME" LOGIN_CRED_DIR2="$L2_DIR2" bash "$helper" "$op" "$slot"
    return
  fi
  if [[ -n "${LOGIN2_PEER_CMD:-}" ]]; then bash -c "$LOGIN2_PEER_CMD \"\$1\" \"\$2\" \"\$3\"" _ "$L2_DEST" "$op" "$slot"; return; fi
  script="$(cat "$PROJ_PATH/src/bash/scripts/agent-login-cred.sh")" || return 1
  ssh -o BatchMode=yes -o ConnectTimeout="${LOGIN_SSH_TIMEOUT:-30}" "$L2_DEST" "bash -c $(printf '%q' "$script") _ $op $slot"
}

# One direction NAME: the lender L's main login (slot 1) -> the borrower B's
# second folder (slot 2). Labels and sha12 only in the output.
_l2_dir() {
  local name="$1" l="$2" b="$3" llab blab lsha lexp bsha bexp
  llab="$(_l2_at "$l" acct 1 2>/dev/null)"; blab="$(_l2_at "$b" acct 2 2>/dev/null)"
  [[ "$llab" =~ ^acct-[0-9a-f]{8}$ ]] || { echo "login2-sync[$name]: WARN the lender's main login names no account (${llab:-unreachable}): nothing copied"; L2_RC=1; return; }
  read -r lsha lexp _ <<<"$(_l2_at "$l" stat 1 2>/dev/null)"
  read -r bsha bexp _ <<<"$(_l2_at "$b" stat 2 2>/dev/null)"
  [[ "$lsha" =~ ^[0-9a-f]{12}$ ]] || { echo "login2-sync[$name]: WARN no credential in the lender's main login: nothing copied"; L2_RC=1; return; }
  [[ "$bexp" =~ ^[0-9]+$ ]] || bexp=0
  if [[ "$blab" != "$llab" ]]; then
    _l2_put "$name" "$l" 1 "$b" 2 "$lsha" "replaced the stale account ${blab:-none} with $llab" acct
  elif [[ "$lsha" == "$bsha" ]]; then echo "login2-sync[$name]: up to date ($llab, $lsha)"
  elif (( lexp > bexp )); then _l2_put "$name" "$l" 1 "$b" 2 "$lsha" "copied $llab $lsha, expires $(_l2_utc "$lexp")"
  elif (( bexp > lexp )); then _l2_back "$name" "$l" "$b" "$llab" "$bsha" "$bexp"
  else echo "login2-sync[$name]: WARN $llab differs ($lsha, $bsha) with the same expiry: not copied"; fi
}

# The borrower's second folder holds a NEWER copy of the same account (its
# seats renewed it): back into the lender's main login, only when it probes ok.
_l2_back() {
  local name="$1" l="$2" b="$3" lab="$4" bsha="$5" bexp="$6" pv
  pv="$(_l2_at "$b" probe 2 2>/dev/null | sed -n 1p)"
  [[ "${pv%% *}" == ok ]] || { echo "login2-sync[$name]: WARN the second folder's newer $lab ($bsha) does not work there (${pv%% *}): not copied back"; return; }
  _l2_put "$name" "$b" 2 "$l" 1 "$bsha" "copied back the newer $lab $bsha, expires $(_l2_utc "$bexp"), into the lender's main login"
}

# Copy the credential FROM/FSLOT -> TO/TSLOT (and with "acct" the two
# .claude.json fields); the put must print SHA. Dry run: the PLAN line.
_l2_put() {
  local name="$1" from="$2" fs="$3" to="$4" ts="$5" sha="$6" what="$7" acct="${8:-}" got
  [[ "$L2_DRY" == 1 ]] && { echo "login2-sync[$name]: PLAN $what (DRY_RUN)"; return 0; }
  got="$(_l2_at "$from" get "$fs" 2>/dev/null | _l2_at "$to" put "$ts" 2>/dev/null | tail -n 1)"
  [[ "$got" == "$sha" ]] || { echo "login2-sync[$name]: FAILED the copy ($what)"; L2_RC=1; return 1; }
  if [[ -n "$acct" ]]; then
    got="$(_l2_at "$from" acctget "$fs" 2>/dev/null | _l2_at "$to" acctput "$ts" 2>/dev/null | tail -n 1)"
    [[ "$got" =~ ^acct- ]] || { echo "login2-sync[$name]: FAILED the account fields ($what)"; L2_RC=1; return 1; }
  fi
  echo "login2-sync[$name]: $what"
}

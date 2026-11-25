#!/bin/bash
#------------------------------------------------------------------------------
# @description Copy an agent CLI login (agy, claude) from one box to another
# @description (SPL-6487; owner HUM-10 t1 2d0a9f79 msg 72a9aaee: "A - New
# @description generic do_spl_agent_cred_sync; login2-sync becomes a wrapper",
# @description "N - No, on demand only"): no cron row runs it. One direction,
# @description CRED_SRC_BOX -> CRED_DST_BOX, box tags; one of them is this box
# @description (SPOOL_BOX_TAG), the other a peer of box.env (SPOOL_LOGIN_PEERS
# @description or SPOOL_LOGIN2_PEER, <tag>=<ssh dest>), reached over ssh from
# @description here. The files of a login are cnf, per vendor and slot
# @description (env.box.agent_cred_sync), each under the agent user's home as
# @description getent reads it on its own box. Every file op is
# @description agent-login-cred.sh's (its f-ops), run as the agent user.
# @description Guards (those of do_spl_agent_login2_sync, SPL-2943/3023/5695):
# @description   1. newer only: copied when the source token's expiry (cnf
# @description      expiry, a jq path: claude claudeAiOauth.expiresAt, agy
# @description      token.expiry) is later than the target's, or the target
# @description      has none; equal files = up to date. A source file missing
# @description      = REFUSED, exit 2.
# @description   2. claude by account label (acct-<8 hex>): slot main is never
# @description      written with another label (REFUSED, exit 2); slot 2 with
# @description      another label is replaced at once (a stale account).
# @description   3. each file temp + mv as the agent user, mode 600, the old
# @description      one kept as <file>.bak-cred-<UTC>.
# @description   4. after the copy one headless prompt on the target box as the
# @description      agent user (`agy -p` / `claude -p`); not ok = every file put
# @description      back from its .bak (a new one removed), exit 1.
# @description Prints only sha prefixes, the account label and the expiry: never
# @description content. CRED_VENDOR=claude CRED_SLOT=2 with no box is the
# @description second-folder sync of box.env: do_spl_agent_login2_sync, whose
# @description thin wrapper this is. Dry run unless DRY_RUN=0.
# @param CRED_VENDOR (required) - agy or claude (a vendor of cnf env.box.agent_cred_sync)
# @param CRED_SRC_BOX (optional) - the box tag the login is copied from; needed with CRED_DST_BOX
# @param CRED_DST_BOX (optional) - the box tag the login is copied to
# @param CRED_SLOT (optional) - the target's slot: main (default), or 2 for claude, its second config folder; the source is always its main login
# @param CRED_AGENT_USER (optional) - default SPOOL_AGENT_USER (env, else box.env), else this user
# @param DRY_RUN (optional) - 1 (default) or 0
# @param CRED_SYNC_CNF (optional) - default <checkout>/<org>-<app>-cnf/<org>-<app>/all.env.yaml
# @param CRED_PEERS (optional) - "<tag>=<ssh dest>,..." in place of box.env's peers
# @param CRED_PEER_CMD (optional, tests) - runs a helper op on a peer in place of ssh: <dest> <op> <args...>
# @param CRED_AGENT_HOME (optional, tests) - the agent user's home here (default: from getent)
# @param CRED_SUDO (optional, tests) - the prefix that runs as the agent user here ("" = none)
# @example CRED_VENDOR=agy CRED_SRC_BOX=<this box tag> CRED_DST_BOX=<peer tag> ./run -a do_spl_agent_cred_sync
# @example CRED_VENDOR=claude CRED_SLOT=2 CRED_SRC_BOX=<peer tag> CRED_DST_BOX=<this box tag> DRY_RUN=0 ./run -a do_spl_agent_cred_sync
#------------------------------------------------------------------------------
# _cs_deps: the login2 sync (its _l2_ helpers), sourced on the first call so
# the ./run loader keeps this file lazy (spec 027, p8-01)
_cs_deps() {
  declare -F _l2_sync >/dev/null || source "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/spl-agent-login2-sync.func.sh"
}

do_spl_agent_cred_sync() {
  local vendor="${CRED_VENDOR:-}" slot="${CRED_SLOT:-main}" dry="${DRY_RUN:-1}"
  _cs_deps
  if [[ "$vendor" == claude && "$slot" == 2 && -z "${CRED_SRC_BOX:-}${CRED_DST_BOX:-}" ]]; then
    _l2_sync; return
  fi
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  CS_NAME="$vendor $slot ${CRED_SRC_BOX:-?} -> ${CRED_DST_BOX:-?}"
  _cs_cnf "$vendor" "$slot" || return 2
  _cs_boxes || return 2
  _cs_user || return 1
  CS_DRY="$dry"
  _cs_sync
}

_cs_say() { echo "cred-sync[$CS_NAME]: $*"; }

# The cnf of the vendor: the source's main slot (CS_SFILES, CS_SACCT) and the
# target's slot (CS_FILES, CS_ACCT, CS_EXP, CS_PROOF, CS_PENV, CS_PARGS).
_cs_cnf() {
  local vendor="$1" slot="$2" cnf j m
  [[ "$vendor" =~ ^[a-z0-9]+$ && "$slot" =~ ^[a-z0-9]+$ ]] || { _cs_say "REFUSED CRED_VENDOR and CRED_SLOT are names, got '$vendor' '$slot'"; return 1; }
  [[ "$(basename "${PROJ_PATH:?PROJ_PATH unset}")" =~ ^([a-z]+-[a-z]+)-orc$ ]] || { _cs_say "FATAL cannot read <org>-<app> from $PROJ_PATH"; return 1; }
  cnf="${CRED_SYNC_CNF:-$APP_PATH/${BASH_REMATCH[1]}-cnf/${BASH_REMATCH[1]}/all.env.yaml}"
  j="$(yq -o json ".env.box.agent_cred_sync.\"$vendor\".\"$slot\" // null" "$cnf" 2>/dev/null)"
  jq -e '.files | arrays | length > 0' >/dev/null 2>&1 <<<"$j" ||
    { _cs_say "REFUSED no cnf env.box.agent_cred_sync.$vendor.$slot.files ($vendor $slot is no vendor slot)"; return 1; }
  m="$(yq -o json ".env.box.agent_cred_sync.\"$vendor\".main // null" "$cnf" 2>/dev/null)"
  mapfile -t CS_FILES < <(jq -r '.files[]' <<<"$j"); mapfile -t CS_SFILES < <(jq -r '.files // [] | .[]' <<<"$m")
  CS_SACCT="$(jq -r '.account // ""' <<<"$m")"
  CS_EXP="$(jq -r '.expiry // ""' <<<"$j")"; CS_ACCT="$(jq -r '.account // ""' <<<"$j")"
  CS_PROOF="$(jq -r '.proof // ""' <<<"$j")"; CS_PENV="$(jq -r '.proof_env // "-"' <<<"$j")"
  mapfile -t CS_PARGS < <(jq -r '.proof_args // [] | .[]' <<<"$j")
  [[ -n "$CS_PROOF" ]] || { _cs_say "REFUSED no cnf proof CLI for $vendor $slot"; return 1; }
  [[ ${#CS_SFILES[@]} == "${#CS_FILES[@]}" && "${CS_SACCT:+a}" == "${CS_ACCT:+a}" ]] ||
    { _cs_say "REFUSED cnf $vendor main and $slot differ in their files or account"; return 1; }
}

# CS_SRC / CS_DST: "here" or the peer's ssh destination.
_cs_boxes() {
  local s="${CRED_SRC_BOX:-}" d="${CRED_DST_BOX:-}" here t
  [[ -n "$s" && -n "$d" ]] || { _cs_say "REFUSED CRED_SRC_BOX and CRED_DST_BOX are both needed"; return 1; }
  for t in "$s" "$d"; do [[ "$t" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { _cs_say "REFUSED '$t' is no box tag"; return 1; }; done
  [[ "$s" != "$d" ]] || { _cs_say "REFUSED the source and the target are the same box"; return 1; }
  here="${SPOOL_BOX_TAG:-$(sed -n 's/^SPOOL_BOX_TAG=//p' "$(_l2_box_env)" 2>/dev/null | tail -1 | tr -d "\"' ")}"
  [[ "$s" == "$here" || "$d" == "$here" ]] || { _cs_say "REFUSED neither box is this one (${here:-no SPOOL_BOX_TAG}): the copy runs from one of them"; return 1; }
  CS_SRC="$(_cs_dest "$s" "$here")"; CS_DST="$(_cs_dest "$d" "$here")"
  [[ -n "$CS_SRC" && -n "$CS_DST" ]] || { _cs_say "REFUSED no ssh destination for the peer (SPOOL_LOGIN_PEERS=<tag>=<dest> in box.env)"; return 1; }
}

_cs_dest() {
  local p
  [[ "$1" == "$2" ]] && { echo here; return; }
  if [[ -n "${CRED_PEERS+x}" ]]; then p="$CRED_PEERS"
  else p="$(sed -n 's/^SPOOL_LOGIN_PEERS=//p; s/^SPOOL_LOGIN2_PEER=//p' "$(_l2_box_env)" 2>/dev/null | tr -d "\"'")"; fi
  awk -F= -v t="$1" '$1 == t && $2 != "" && !d { print substr($0, length(t) + 2); d = 1 }' <<<"${p//[, ]/$'\n'}"
}

_cs_user() {
  local u="${CRED_AGENT_USER:-${SPOOL_AGENT_USER:-}}"
  [[ -n "$u" ]] || u="$(sed -n 's/^SPOOL_AGENT_USER=\([a-z_][a-z0-9_-]*\)$/\1/p' "$(_l2_box_env)" 2>/dev/null | tail -1)"
  [[ -n "$u" ]] || u="$(id -un)"
  [[ "$u" =~ ^[a-z_][a-z0-9_-]*$ ]] || { _cs_say "FATAL '$u' is no user name"; return 1; }
  CS_USER="$u"
}

# _cs_at here|<dest> OP ARG...: one agent-login-cred.sh op on that box.
_cs_at() {
  local at="$1" helper="$PROJ_PATH/src/bash/scripts/agent-login-cred.sh" e=() a; shift
  if [[ "$at" == here ]]; then
    e=(LOGIN_AGENT_USER="$CS_USER")
    [[ -n "${CRED_AGENT_HOME:-}" ]] && e+=(LOGIN_AGENT_HOME="$CRED_AGENT_HOME")
    [[ -n "${CRED_SUDO+x}" ]] && e+=(LOGIN_SUDO="$CRED_SUDO")
    env "${e[@]}" bash "$helper" "$@"; return
  fi
  if [[ -n "${CRED_PEER_CMD:-}" ]]; then bash -c "$CRED_PEER_CMD \"\$@\"" _ "$at" "$@"; return; fi
  a="$(printf ' %q' "$@")"
  ssh -o BatchMode=yes -o ConnectTimeout="${LOGIN_SSH_TIMEOUT:-30}" "$at" \
    "LOGIN_AGENT_USER=$(printf '%q' "$CS_USER") bash -c $(printf '%q' "$(cat "$helper")") _$a"
}

# Read both sides, decide (guards 1 and 2), then copy and prove.
_cs_sync() {
  local i f sst dst sexp=0 dexp=0 same=1 slab="" dlab="" what
  CS_SSHA=(); CS_DNEW=()
  for i in "${!CS_FILES[@]}"; do
    f="${CS_FILES[$i]}"
    sst="$(_cs_at "$CS_SRC" fstat "${CS_SFILES[$i]}" "$( ((i == 0)) && echo "$CS_EXP")" 2>/dev/null)"
    dst="$(_cs_at "$CS_DST" fstat "$f" "$( ((i == 0)) && echo "$CS_EXP")" 2>/dev/null)"
    [[ "$sst" =~ ^[0-9a-f]{12}\ [0-9]+$ ]] || { _cs_say "REFUSED the source has no file $((i + 1)) of ${#CS_FILES[@]} of the login (${sst:-unreachable}): nothing copied"; return 2; }
    CS_SSHA+=("${sst%% *}"); CS_DNEW+=("$([[ "$dst" == none ]] && echo 1 || echo 0)")
    [[ "${sst%% *}" == "${dst%% *}" ]] || same=0
    ((i == 0)) && { sexp="${sst##* }"; [[ "$dst" =~ \ ([0-9]+)$ ]] && dexp="${BASH_REMATCH[1]}"; }
  done
  if [[ -n "$CS_ACCT" ]]; then
    slab="$(_cs_at "$CS_SRC" facct "$CS_SACCT" 2>/dev/null)"; dlab="$(_cs_at "$CS_DST" facct "$CS_ACCT" 2>/dev/null)"
    [[ "$slab" =~ ^acct-[0-9a-f]{8}$ ]] || { _cs_say "REFUSED the source login names no account (${slab:-unreachable}): nothing copied"; return 2; }
    [[ "$(_cs_at "$CS_DST" fstat "$CS_ACCT" 2>/dev/null)" == none ]] && CS_ANEW=1 || CS_ANEW=0
  fi
  if [[ -n "$slab" && "$dlab" != "$slab" && "$dlab" != none && "${CRED_SLOT:-main}" == main ]]; then
    _cs_say "REFUSED the target's main login is another account ($dlab, the source $slab): a main login is never written with another label"; return 2
  elif [[ -n "$slab" && "$dlab" != "$slab" ]]; then what="replaced the stale account ${dlab:-none} with $slab"
  elif ((same)); then _cs_say "up to date (${slab:+$slab, }${CS_SSHA[*]})"; return 0
  elif [[ "${CS_DNEW[0]}" == 1 ]] || ((sexp > dexp)); then what="copied ${slab:+$slab }${CS_SSHA[*]}, expires $(_l2_utc $((sexp * 1000)))"
  else _cs_say "the source is not newer (expires $(_l2_utc $((sexp * 1000))), the target $(_l2_utc $((dexp * 1000)))): nothing copied"; return 0
  fi
  [[ "$CS_DRY" == 1 ]] && { _cs_say "PLAN $what, then the $CS_PROOF -p proof (DRY_RUN)"; return 0; }
  _cs_copy "$what"
}

# Guard 3 and 4: every file over, then the proof on the target; not ok = restore.
_cs_copy() {
  local what="$1" ts i got pv
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  for i in "${!CS_FILES[@]}"; do
    got="$(_cs_at "$CS_SRC" fget "${CS_SFILES[$i]}" 2>/dev/null | _cs_at "$CS_DST" fput "${CS_FILES[$i]}" "$ts" 2>/dev/null | tail -n 1)"
    [[ "$got" == "${CS_SSHA[$i]}" ]] || { _cs_say "FAILED the copy of file $((i + 1)) ($what): $(_cs_restore "$ts" "$i")"; return 1; }
  done
  if [[ -n "$CS_ACCT" ]]; then
    got="$(_cs_at "$CS_SRC" facctget "$CS_SACCT" 2>/dev/null | _cs_at "$CS_DST" facctput "$CS_ACCT" "$ts" 2>/dev/null | tail -n 1)"
    [[ "$got" =~ ^acct- ]] || { _cs_say "FAILED the account fields ($what): $(_cs_restore "$ts" "${#CS_FILES[@]}" acct)"; return 1; }
  fi
  pv="$(_cs_at "$CS_DST" fprobe "$CS_PROOF" "$CS_PENV" "${CS_PARGS[@]}" 2>/dev/null | sed -n 1p)"
  if [[ "${pv%% *}" != ok ]]; then
    _cs_say "FAILED the $CS_PROOF -p proof on the target (${pv%% *}): $(_cs_restore "$ts" "${#CS_FILES[@]}" acct)"; return 1
  fi
  _cs_say "$what; the $CS_PROOF -p proof is ok"
}

# _cs_restore TS N [acct]: files 0..N (and the account file) back from .bak-cred-TS.
_cs_restore() {
  local ts="$1" n="$2" i new out=()
  for ((i = 0; i <= n && i < ${#CS_FILES[@]}; i++)); do
    new=(); [[ "${CS_DNEW[$i]}" == 1 ]] && new=(new)
    out+=("$(_cs_at "$CS_DST" frestore "${CS_FILES[$i]}" "$ts" "${new[@]}" 2>/dev/null)")
  done
  if [[ -n "${3:-}" && -n "$CS_ACCT" ]]; then
    new=(); [[ "${CS_ANEW:-0}" == 1 ]] && new=(new)
    out+=("$(_cs_at "$CS_DST" frestore "$CS_ACCT" "$ts" "${new[@]}" 2>/dev/null)")
  fi
  echo "the target put back from its .bak (${out[*]})"
}

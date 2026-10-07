#!/bin/bash
#------------------------------------------------------------------------------
# @description READ-ONLY: the agent vendor split of THIS box, target vs actual,
# @description and the vendor the next lane spawn should go to. The target is
# @description cnf env.box.agent_split (all.env.yaml); the actual is the last
# @description `window` spawns in $SPOOL_ROOT/registry.tsv (role seats
# @description 001..003 left out, one row per id). APPROXIMATE, never a quota:
# @description - spec writing or review (LANE_MIX_KIND=spec) -> agy
# @description - secrets or personal data (LANE_MIX_SENSITIVE=1, or
# @description   LANE_MIX_KIND=secret) -> claude
# @description - the most complex coding (LANE_MIX_KIND=hard, or
# @description   LANE_MIX_DIFFICULTY >= 60) -> claude
# @description - kind unset/default and difficulty unset -> grok
# @description - easy (difficulty < 60) -> the vendor furthest below target by
# @description   MORE than the tolerance; inside the band, the largest
# @description   non-claude share
# @description A vendor whose CLI is not installed, or whose cnf auth_marker is
# @description absent from the agent user's home, is skipped and its share goes
# @description to claude. So is one out of quota: the watchdog saw one of its
# @description lanes on this box on an S2 kind=limit screen within
# @description LANE_MIX_LIMIT_FRESH s (spec 102 T029; grok's weekly limit).
# @description Prints a table, then `pick=<vendor> launcher=...`.
# @param LANE_MIX_KIND (optional) - spec, secret, hard or default; unset is
# @param   default (grok, unless a harder signal below says otherwise)
# @param LANE_MIX_DIFFICULTY (optional) - 0..100, the task against your own
# @param   capacity; unset is the default (grok) and prints the easy pick as
# @param   `next`. It is not claude.
# @param LANE_MIX_SENSITIVE (optional) - 1: the work carries secrets/personal data
# @param LANE_MIX_SPLIT (optional) - "claude=N grok=N agy=N qwen=N", overrides
# @param   the cnf numbers (do_spl_agent_split_show prints this line)
# @param LANE_MIX_CNF (optional) - default <checkout>/csi-spl-cnf/csi-spl/all.env.yaml
# @param LANE_MIX_REGISTRY (optional) - default $SPOOL_ROOT/registry.tsv
# @param LANE_MIX_AGENT_HOME (optional) - default the home of SPOOL_AGENT_USER
# @param   (environment, else $SPOOL_ROOT/box.env), else $HOME
# @param LANE_MIX_WD_DIR (optional) - default $SPOOL_ROOT/dispatch/wd, the
# @param   watchdog state whose ctx*/<id>/out.s2 carries the limit verdicts
# @param LANE_MIX_LIMIT_FRESH (optional) - s a limit verdict holds, default 21600
# @example ./run -a do_spl_lane_mix
# @example LANE_MIX_KIND=spec ./run -a do_spl_lane_mix
# @example LANE_MIX_DIFFICULTY=30 ./run -a do_spl_lane_mix
# @example LANE_MIX_DIFFICULTY=30 LANE_MIX_SENSITIVE=1 ./run -a do_spl_lane_mix
#------------------------------------------------------------------------------
LANE_MIX_VENDORS=(claude grok agy qwen)

do_spl_lane_mix() {
  do_require_bin yq || return 1
  local root="${SPOOL_ROOT:-/var/spool-hub}" org_app
  [[ "$(basename "${PROJ_PATH:?PROJ_PATH unset}")" =~ ^([a-z]+-[a-z]+)-orc$ ]] || {
    do_log "FATAL cannot read <org>-<app> from $PROJ_PATH"; return 1; }
  org_app="${BASH_REMATCH[1]}"
  local cnf="${LANE_MIX_CNF:-$APP_PATH/$org_app-cnf/$org_app/all.env.yaml}"
  local reg="${LANE_MIX_REGISTRY:-$root/registry.tsv}"
  local diff="${LANE_MIX_DIFFICULTY:-}" sens="${LANE_MIX_SENSITIVE:-0}"
  local kind="${LANE_MIX_KIND:-}"
  [[ -r "$cnf" ]] || { do_log "FATAL no cnf $cnf"; return 1; }
  [[ -z "$diff" || ( "$diff" =~ ^[0-9]{1,3}$ && "$diff" -le 100 ) ]] || {
    do_log "FATAL LANE_MIX_DIFFICULTY must be 0..100, got '$diff'"; return 1; }
  [[ "$sens" =~ ^[01]$ ]] || { do_log "FATAL LANE_MIX_SENSITIVE must be 0 or 1, got '$sens'"; return 1; }
  [[ "${LANE_MIX_LIMIT_FRESH:-0}" =~ ^[0-9]+$ ]] || {
    do_log "FATAL LANE_MIX_LIMIT_FRESH must be whole seconds, got '$LANE_MIX_LIMIT_FRESH'"; return 1; }
  case "$kind" in
    ""|default|spec|secret|hard) ;;
    *) do_log "FATAL LANE_MIX_KIND must be spec, secret, hard or default, got '$kind'"; return 1 ;;
  esac

  declare -gA _LM_TGT=() _LM_EFF=() _LM_CNT=() _LM_PCT=() _LM_AVAIL=()
  _spl_lane_mix_target "$cnf" || return 1
  _spl_lane_mix_avail "$root" "$cnf" "$reg"
  _spl_lane_mix_actual "$reg"
  _spl_lane_mix_table "$cnf" "$reg"
  _spl_lane_mix_easy

  if [[ "$sens" == 1 || "$kind" == secret ]]; then
    _spl_lane_mix_pick claude "data rule: secrets or personal data always go to claude"
  elif [[ "$kind" == spec ]]; then
    if [[ "${_LM_AVAIL[agy]}" == yes ]]; then
      _spl_lane_mix_pick agy "kind spec: specifications go to agy"
    else
      _spl_lane_mix_pick claude "kind spec but agy is skipped (${_LM_AVAIL[agy]}); share to claude"
    fi
  elif [[ "$kind" == hard ]]; then
    _spl_lane_mix_pick claude "kind hard: the most complex coding goes to claude"
  elif [[ -z "$diff" ]]; then
    printf 'next easy=%s (%s) default=grok\n' "$_LM_EASY" "$_LM_EASY_WHY"
    if [[ "${_LM_AVAIL[grok]}" == yes ]]; then
      _spl_lane_mix_pick grok "difficulty unset: default is grok"
    else
      _spl_lane_mix_pick "$_LM_EASY" "difficulty unset: default grok is skipped (${_LM_AVAIL[grok]}); $_LM_EASY_WHY"
    fi
  elif (( diff >= 60 )); then
    _spl_lane_mix_pick claude "difficulty $diff >= 60: hard work goes to claude"
  else
    _spl_lane_mix_pick "$_LM_EASY" "difficulty $diff < 60: $_LM_EASY_WHY"
  fi
}

# _spl_lane_mix_target <cnf> -> _LM_TGT, _LM_TOL, _LM_WIN from cnf, or from
# LANE_MIX_SPLIT; refuses a split that is not four whole numbers summing to 100
_spl_lane_mix_target() {
  local cnf="$1" v sum=0
  _LM_TOL="$(yq -r '.env.box.agent_split.tolerance // 5' "$cnf")"
  _LM_WIN="$(yq -r '.env.box.agent_split.window // 20' "$cnf")"
  for v in "${LANE_MIX_VENDORS[@]}"; do _LM_TGT[$v]="$(yq -r ".env.box.agent_split.$v // 0" "$cnf")"; done
  if [[ -n "${LANE_MIX_SPLIT:-}" ]]; then
    [[ "$LANE_MIX_SPLIT" =~ ^claude=([0-9]+)\ grok=([0-9]+)\ agy=([0-9]+)\ qwen=([0-9]+)$ ]] || {
      do_log "FATAL LANE_MIX_SPLIT must read 'claude=N grok=N agy=N qwen=N', got '$LANE_MIX_SPLIT'"; return 1; }
    _LM_TGT[claude]="${BASH_REMATCH[1]}" _LM_TGT[grok]="${BASH_REMATCH[2]}"
    _LM_TGT[agy]="${BASH_REMATCH[3]}" _LM_TGT[qwen]="${BASH_REMATCH[4]}"
  fi
  for v in "${LANE_MIX_VENDORS[@]}"; do
    [[ "${_LM_TGT[$v]}" =~ ^[0-9]{1,3}$ ]] || { do_log "FATAL agent_split.$v must be a whole number, got '${_LM_TGT[$v]}'"; return 1; }
    sum=$(( sum + _LM_TGT[$v] ))
  done
  (( sum == 100 )) || { do_log "FATAL agent_split sums to $sum, not 100"; return 1; }
  [[ "$_LM_TOL" =~ ^[0-9]{1,2}$ && "$_LM_WIN" =~ ^[0-9]{1,3}$ && "$_LM_WIN" -gt 0 ]] || {
    do_log "FATAL agent_split tolerance/window must be whole numbers, got '$_LM_TOL'/'$_LM_WIN'"; return 1; }
}

# _spl_lane_mix_avail <spool-root> <cnf> <registry> -> _LM_AVAIL, _LM_EFF:
# claude is the floor and always there; a skipped vendor's share moves to claude
_spl_lane_mix_avail() {
  local user home v lim
  user="$(_spl_lane_mix_user "$1")"
  home="$(_spl_lane_mix_home "$user")"
  _LM_EFF[claude]="${_LM_TGT[claude]}" _LM_AVAIL[claude]=yes
  for v in grok agy qwen; do
    _LM_AVAIL[$v]="$(_spl_lane_mix_cli "$v" "$user" "$home" "$2")"
    if [[ "${_LM_AVAIL[$v]}" == yes ]]; then
      lim="$(_spl_lane_mix_limit "$v" "$1" "$3")"
      [[ -z "$lim" ]] || _LM_AVAIL[$v]="$v limit ($lim)"
    fi
    if [[ "${_LM_AVAIL[$v]}" == yes ]]; then _LM_EFF[$v]="${_LM_TGT[$v]}"
    else _LM_EFF[$v]=0; _LM_EFF[claude]=$(( _LM_EFF[claude] + _LM_TGT[$v] )); fi
  done
}

# _spl_lane_mix_actual <registry> -> _LM_CNT, _LM_PCT, _LM_N: the last window
# spawns, one row per id (its latest), role seats 001..003 out
_spl_lane_mix_actual() {
  local v kind
  _LM_N=0
  for v in "${LANE_MIX_VENDORS[@]}"; do _LM_CNT[$v]=0; done
  if [[ -r "$1" ]]; then
    while read -r kind; do
      [[ -n "${_LM_CNT[$kind]+x}" ]] || continue
      _LM_CNT[$kind]=$(( _LM_CNT[$kind] + 1 )); _LM_N=$(( _LM_N + 1 ))
    done < <(awk -F'\t' '$1 !~ /-00[1-3]$/ && NF >= 5 { k[$1]=$2; t[$1]=$5 } END { for (i in k) print t[i] "\t" k[i] }' "$1" |
             sort | tail -n "$_LM_WIN" | cut -f2)
  fi
  for v in "${LANE_MIX_VENDORS[@]}"; do
    _LM_PCT[$v]=$(( _LM_N > 0 ? (_LM_CNT[$v] * 100 + _LM_N / 2) / _LM_N : 0 ))
  done
}

# _spl_lane_mix_table <cnf> <registry> -> the target vs actual table
_spl_lane_mix_table() {
  local v st
  printf 'window=%s n=%s tolerance=%s cnf=%s registry=%s\n' "$_LM_WIN" "$_LM_N" "$_LM_TOL" "${1#"$APP_PATH"/}" "$2"
  printf '%-7s %6s %9s %6s %5s %-4s %s\n' vendor target effective actual count cli status
  for v in "${LANE_MIX_VENDORS[@]}"; do
    if [[ "${_LM_AVAIL[$v]}" != yes ]]; then st="skip (${_LM_AVAIL[$v]}; share to claude)"
    elif (( _LM_PCT[$v] < _LM_EFF[$v] - _LM_TOL )); then st=under
    elif (( _LM_PCT[$v] > _LM_EFF[$v] + _LM_TOL )); then st=over
    else st=ok; fi
    printf '%-7s %5s%% %8s%% %5s%% %5s %-4s %s\n' "$v" "${_LM_TGT[$v]}" "${_LM_EFF[$v]}" "${_LM_PCT[$v]}" \
      "${_LM_CNT[$v]}" "$([[ ${_LM_AVAIL[$v]} == yes ]] && echo yes || echo no)" "$st"
  done
}

# _spl_lane_mix_easy -> _LM_EASY, _LM_EASY_WHY: the vendor furthest below its
# share beyond the band, else the largest non-claude share there, else claude
_spl_lane_mix_easy() {
  local v d best=-1
  _LM_EASY=""
  for v in grok agy qwen claude; do
    (( _LM_EFF[$v] > 0 )) || continue
    d=$(( _LM_EFF[$v] - _LM_PCT[$v] ))
    if (( d > _LM_TOL && d > best )); then _LM_EASY="$v" best="$d"; fi
  done
  if [[ -n "$_LM_EASY" ]]; then
    _LM_EASY_WHY="$_LM_EASY is ${best} points under its ${_LM_EFF[$_LM_EASY]}% (band $_LM_TOL)"
    return 0
  fi
  best=0
  for v in grok agy qwen; do (( _LM_EFF[$v] > best )) && { _LM_EASY="$v"; best="${_LM_EFF[$v]}"; }; done
  _LM_EASY="${_LM_EASY:-claude}" _LM_EASY_WHY="mix inside the band; easy work goes to the largest non-claude share"
  [[ "$_LM_EASY" == claude ]] && _LM_EASY_WHY="no other vendor is there on this box"
  return 0
}

_spl_lane_mix_pick() { printf 'pick=%s launcher=/%s-spawn reason=%s\n' "$1" "$1" "$2"; }

# _spl_lane_mix_user <spool-root> -> the agent user (SPOOL_AGENT_USER, else
# box.env), empty when LANE_MIX_AGENT_HOME names the home directly
_spl_lane_mix_user() {
  [[ -n "${LANE_MIX_AGENT_HOME:-}" ]] && return 0
  local u="${SPOOL_AGENT_USER:-}"
  [[ -z "$u" && -r "$1/box.env" ]] && u="$(sed -n 's/^SPOOL_AGENT_USER=//p' "$1/box.env" | tail -n 1)"
  echo "$u"
}

# _spl_lane_mix_home <user> -> the agent user's home (where the CLIs live)
_spl_lane_mix_home() {
  [[ -n "${LANE_MIX_AGENT_HOME:-}" ]] && { echo "$LANE_MIX_AGENT_HOME"; return; }
  local h=""
  [[ -n "$1" ]] && h="$(getent passwd "$1" | cut -d: -f6)"
  echo "${h:-$HOME}"
}

# _spl_lane_mix_test <user> <test-args...> -> test(1), as the agent user when
# that is someone else: its home is closed to the box user
_spl_lane_mix_test() {
  local u="$1"; shift
  if [[ -z "$u" || "$u" == "$(id -un)" ]]; then test "$@"
  else sudo -n -u "$u" test "$@" 2>/dev/null; fi
}

# _spl_lane_mix_cli <vendor> <user> <home> <cnf> -> "yes", or why it is skipped
_spl_lane_mix_cli() {
  local v="$1" user="$2" home="$3" var bin marker
  var="${v^^}_BIN"
  bin="${!var:-$home/.local/bin/$v}"
  [[ "$bin" == /* ]] || bin="$(command -v "$bin" 2>/dev/null)"
  [[ -n "$bin" ]] && _spl_lane_mix_test "$user" -x "$bin" || { echo "no $v cli"; return; }
  marker="$(yq -r ".env.box.agent_split.auth_marker.$v // \"\"" "$4")"
  [[ -z "$marker" ]] || _spl_lane_mix_test "$user" -e "$home/$marker" || { echo "$v not signed in"; return; }
  echo yes
}

# _spl_lane_mix_limit <vendor> <spool-root> <registry> -> "<id> S2 kind=limit
# <age> ago" for the newest watchdog verdict (ctx*/<id>/out.s2) within
# LANE_MIX_LIMIT_FRESH s on one of that vendor's lanes, else nothing. The
# vendor is the id's registry kind, else its prefix (spec 061: c g a q).
_spl_lane_mix_limit() {
  local v="$1" wd="${LANE_MIX_WD_DIR:-$2/dispatch/wd}" fresh="${LANE_MIX_LIMIT_FRESH:-21600}"
  local now f t id k best=-1 hit=""
  now="$(date +%s)"
  for f in "$wd"/ctx*/*/out.s2; do
    grep -q '^HIT S2 kind=limit' "$f" 2>/dev/null || continue
    t="$(stat -c %Y "$f" 2>/dev/null)" || continue
    (( now - t <= fresh && t > best )) || continue
    id="$(basename "$(dirname "$f")")"
    k="$(awk -F'\t' -v i="$id" '$1 == i {k = $2} END {print k}' "$3" 2>/dev/null)"
    [[ -n "$k" ]] || case "${id:0:2}" in c-) k=claude ;; g-) k=grok ;; a-) k=agy ;; q-) k=qwen ;; esac
    [[ "$k" == "$v" ]] || continue
    best="$t" hit="$id S2 kind=limit $(( (now - t) / 60 ))m ago"
  done
  echo "$hit"
}

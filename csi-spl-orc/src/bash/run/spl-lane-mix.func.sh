#!/bin/bash
#------------------------------------------------------------------------------
# @description The agent vendor split of THIS box, target vs actual,
# @description and the vendor the next lane spawn should go to. The target is
# @description cnf env.box.agent_split (all.env.yaml); the actual is the last
# @description `window` spawns in $SPOOL_ROOT/registry.tsv (role seats
# @description 001..003 left out, one row per id). APPROXIMATE, never a quota:
# @description - spec writing, review or docs (LANE_MIX_KIND=spec) -> mistral,
# @description   then agy, then claude (owner D5, spec 110); agy when mistral
# @description   holds no share
# @description - secrets or personal data (LANE_MIX_SENSITIVE=1, or
# @description   LANE_MIX_KIND=secret) -> claude
# @description - the most complex coding (LANE_MIX_KIND=hard, or
# @description   LANE_MIX_DIFFICULTY >= 60) -> claude
# @description - kind unset/default and difficulty unset (low-level coding) ->
# @description   mistral first (owner D5), then agy, then claude; grok when
# @description   mistral holds no share, so a share of 0 takes mistral out of
# @description   every kind-first pick and restores grok with no code change
# @description How share and kind combine: the kind picks the FIRST vendor (a
# @description vendor with a share of 0 is never first); the share only drives
# @description the easy nudge below and where a skipped vendor's points go.
# @description - easy (difficulty < 60) -> the vendor furthest below target by
# @description   MORE than the tolerance; inside the band, the largest
# @description   non-claude share
# @description A vendor whose CLI is not installed, or whose cnf auth_marker is
# @description absent from the agent user's home, is skipped. So is one out of
# @description quota: the watchdog saw one of its lanes on this box on an S2
# @description kind=limit screen within LANE_MIX_LIMIT_FRESH s (spec 102 T029;
# @description grok's weekly limit). So is one with a dead key: an S2 kind=auth
# @description verdict on one of its lanes within LANE_MIX_AUTH_FRESH s that is
# @description newer than its auth marker (a re-key touches the marker and ends
# @description the skip; spec 110 2.5). A skipped vendor falls down the fixed chain
# @description grok -> agy -> claude, or mistral -> agy -> claude (owner HUM-10
# @description t1 65f75266: claude is the default ai vendor, the last fallback;
# @description spec 110 D4): a skipped grok's or mistral's pick and share go to
# @description agy when agy is there, else to claude; a skipped agy's and qwen's
# @description go to claude.
# @description The instance setting (rdb 0149, owner HUM-10 t1 41fa1f2d) beats
# @description all of it, on every box: a kind the operator admin switched off
# @description on the Fleet load page, or one paused there, is never picked,
# @description and its share goes down the chain (to the other kinds when
# @description claude is the one off). It is read from the hub like do_spl_box_pick's
# @description target (`spool fleet-load get`); a hub that does not answer, or
# @description no fleet, -> the local checks only, said in every reason. The one
# @description write: a fresh local limit verdict is reported to the hub as a
# @description pause of that kind until the verdict runs out
# @description (`spool fleet-load pause`), so every box skips it.
# @description Prints a table, then `pick=<vendor> launcher=...`, or `pick=hold`
# @description when no kind may take the work (secrets with claude off).
# @param LANE_MIX_KIND (optional) - spec, secret, hard or default; unset is
# @param   default (mistral or grok, unless a harder signal below says otherwise)
# @param LANE_MIX_DIFFICULTY (optional) - 0..100, the task against your own
# @param   capacity; unset is the default (mistral or grok) and prints the easy
# @param   pick as `next`. It is not claude.
# @param LANE_MIX_SENSITIVE (optional) - 1: the work carries secrets/personal data
# @param LANE_MIX_SPLIT (optional) - "claude=N grok=N agy=N qwen=N mistral=N",
# @param   overrides the cnf numbers (do_spl_agent_split_show prints this line);
# @param   the old 4-number form without mistral is still read, as mistral=0
# @param LANE_MIX_CNF (optional) - default <checkout>/csi-spl-cnf/csi-spl/all.env.yaml
# @param LANE_MIX_REGISTRY (optional) - default $SPOOL_ROOT/registry.tsv
# @param LANE_MIX_AGENT_HOME (optional) - default the home of SPOOL_AGENT_USER
# @param   (environment, else $SPOOL_ROOT/box.env), else $HOME
# @param LANE_MIX_WD_DIR (optional) - default $SPOOL_ROOT/dispatch/wd, the
# @param   watchdog state whose ctx*/<id>/out.s2 carries the limit verdicts
# @param LANE_MIX_LIMIT_FRESH (optional) - s a limit verdict holds, default 21600
# @param LANE_MIX_AUTH_FRESH (optional) - s an auth (dead key) verdict holds at
# @param   most, default 604800; a re-key ends it sooner
# @param LANE_MIX_INSTANCE (optional) - 0: do not read the instance setting
# @param LANE_MIX_REPORT (optional) - 0: do not report a limit verdict to the hub
# @param ENV (optional) - dev or prd: the hub to read, default LANE_ENV / lease.conf LEASE_ENV
# @param LANE_HUB_CMD (optional, tests) - replaces the hub call: gets `fleet-load get|pause ...`
# @example ./run -a do_spl_lane_mix
# @example LANE_MIX_KIND=spec ./run -a do_spl_lane_mix
# @example LANE_MIX_DIFFICULTY=30 ./run -a do_spl_lane_mix
# @example LANE_MIX_DIFFICULTY=30 LANE_MIX_SENSITIVE=1 ./run -a do_spl_lane_mix
#------------------------------------------------------------------------------
LANE_MIX_VENDORS=(claude grok agy qwen mistral)

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
  [[ "${LANE_MIX_AUTH_FRESH:-0}" =~ ^[0-9]+$ ]] || {
    do_log "FATAL LANE_MIX_AUTH_FRESH must be whole seconds, got '$LANE_MIX_AUTH_FRESH'"; return 1; }
  case "$kind" in
    ""|default|spec|secret|hard) ;;
    *) do_log "FATAL LANE_MIX_KIND must be spec, secret, hard or default, got '$kind'"; return 1 ;;
  esac

  declare -gA _LM_TGT=() _LM_EFF=() _LM_CNT=() _LM_PCT=() _LM_AVAIL=()
  _spl_lane_mix_target "$cnf" || return 1
  _spl_lane_mix_instance
  _spl_lane_mix_avail "$root" "$cnf" "$reg"
  _spl_lane_mix_actual "$reg"
  _spl_lane_mix_table "$cnf" "$reg"
  _spl_lane_mix_easy
  local -A first=([spec]=agy [default]=grok)
  # owner D5 (spec 110, t1 msg c7970593): docs and low-level coding go to
  # mistral first, while it holds a share
  (( _LM_TGT[mistral] > 0 )) && first=([spec]=mistral [default]=mistral)

  if [[ "$sens" == 1 || "$kind" == secret ]]; then
    if [[ "${_LM_AVAIL[claude]}" == yes ]]; then
      _spl_lane_mix_pick claude "data rule: secrets or personal data always go to claude"
    else
      _spl_lane_mix_pick hold "data rule: secrets or personal data go to claude only, and claude is skipped (${_LM_AVAIL[claude]}): queue the work"
    fi
  elif [[ "$kind" == spec ]]; then
    _spl_lane_mix_want "${first[spec]}" "kind spec: specifications go to ${first[spec]}" "kind spec but ${first[spec]} is skipped (${_LM_AVAIL[${first[spec]}]})"
  elif [[ "$kind" == hard ]]; then
    _spl_lane_mix_want claude "kind hard: the most complex coding goes to claude"
  elif [[ -z "$diff" ]]; then
    printf 'next easy=%s (%s) default=%s\n' "${_LM_EASY:-hold}" "$_LM_EASY_WHY" "${first[default]}"
    _spl_lane_mix_want "${first[default]}" "difficulty unset: default is ${first[default]}" \
      "difficulty unset: default ${first[default]} is skipped (${_LM_AVAIL[${first[default]}]})"
  elif (( diff >= 60 )); then
    _spl_lane_mix_want claude "difficulty $diff >= 60: hard work goes to claude"
  else
    _spl_lane_mix_pick "${_LM_EASY:-hold}" "difficulty $diff < 60: $_LM_EASY_WHY"
  fi
}

# _spl_lane_mix_want <vendor> <reason> [<reason when skipped>] -> the pick
# line: that vendor when it is there, else the next one there down the chain
# grok|mistral -> agy -> claude, else the easy pick, else hold
_spl_lane_mix_want() {
  local why="${3:-$2, but $1 is skipped (${_LM_AVAIL[$1]})}" next chain=grok
  next="$(_spl_lane_mix_next "$1")"
  [[ "$1" == mistral ]] && chain=mistral
  if [[ "${_LM_AVAIL[$1]}" == yes ]]; then _spl_lane_mix_pick "$1" "$2"
  elif [[ -n "$next" ]]; then _spl_lane_mix_pick "$next" "$why; falls to $next (chain $chain -> agy -> claude)"
  elif [[ -n "$_LM_EASY" ]]; then _spl_lane_mix_pick "$_LM_EASY" "$why; $_LM_EASY_WHY"
  else _spl_lane_mix_pick hold "$why; no other kind is there: queue the work"; fi
}

# _spl_lane_mix_target <cnf> -> _LM_TGT, _LM_TOL, _LM_WIN from cnf, or from
# LANE_MIX_SPLIT; refuses a split that is not five (or the old four, mistral
# 0) whole numbers summing to 100
_spl_lane_mix_target() {
  local cnf="$1" v sum=0
  _LM_TOL="$(yq -r '.env.box.agent_split.tolerance // 5' "$cnf")"
  _LM_WIN="$(yq -r '.env.box.agent_split.window // 20' "$cnf")"
  for v in "${LANE_MIX_VENDORS[@]}"; do _LM_TGT[$v]="$(yq -r ".env.box.agent_split.$v // 0" "$cnf")"; done
  if [[ -n "${LANE_MIX_SPLIT:-}" ]]; then
    [[ "$LANE_MIX_SPLIT" =~ ^claude=([0-9]+)\ grok=([0-9]+)\ agy=([0-9]+)\ qwen=([0-9]+)(\ mistral=([0-9]+))?$ ]] || {
      do_log "FATAL LANE_MIX_SPLIT must read 'claude=N grok=N agy=N qwen=N mistral=N', got '$LANE_MIX_SPLIT'"; return 1; }
    _LM_TGT[claude]="${BASH_REMATCH[1]}" _LM_TGT[grok]="${BASH_REMATCH[2]}"
    _LM_TGT[agy]="${BASH_REMATCH[3]}" _LM_TGT[qwen]="${BASH_REMATCH[4]}"
    _LM_TGT[mistral]="${BASH_REMATCH[6]:-0}"
  fi
  for v in "${LANE_MIX_VENDORS[@]}"; do
    [[ "${_LM_TGT[$v]}" =~ ^[0-9]{1,3}$ ]] || { do_log "FATAL agent_split.$v must be a whole number, got '${_LM_TGT[$v]}'"; return 1; }
    sum=$(( sum + _LM_TGT[$v] ))
  done
  (( sum == 100 )) || { do_log "FATAL agent_split sums to $sum, not 100"; return 1; }
  [[ "$_LM_TOL" =~ ^[0-9]{1,2}$ && "$_LM_WIN" =~ ^[0-9]{1,3}$ && "$_LM_WIN" -gt 0 ]] || {
    do_log "FATAL agent_split tolerance/window must be whole numbers, got '$_LM_TOL'/'$_LM_WIN'"; return 1; }
}

# _spl_lane_mix_avail <spool-root> <cnf> <registry> -> _LM_AVAIL, _LM_EFF.
# The instance setting first (off or paused), then the local checks: claude
# is always there locally; the others need their CLI, a sign-in, no dead-key
# verdict since the last re-key (this box's key only, so not reported) and no
# fresh limit verdict (which is reported to the hub as a pause).
_spl_lane_mix_avail() {
  local user home v lim off auth
  user="$(_spl_lane_mix_user "$1")"
  home="$(_spl_lane_mix_home "$user")"
  for v in "${LANE_MIX_VENDORS[@]}"; do
    off="$(_spl_lane_mix_inst_off "$v")"
    if [[ -n "$off" ]]; then _LM_AVAIL[$v]="$off"; continue; fi
    [[ "$v" == claude ]] && { _LM_AVAIL[$v]=yes; continue; }
    _LM_AVAIL[$v]="$(_spl_lane_mix_cli "$v" "$user" "$home" "$2")"
    [[ "${_LM_AVAIL[$v]}" == yes ]] || continue
    auth="$(_spl_lane_mix_auth "$v" "$1" "$3" "$user" "$home" "$2")"
    [[ -z "$auth" ]] || { _LM_AVAIL[$v]="$v auth ($auth)"; continue; }
    lim="$(_spl_lane_mix_limit "$v" "$1" "$3")"
    [[ -z "$lim" ]] && continue
    _LM_AVAIL[$v]="$v limit (${lim#*$'\t'})"
    _spl_lane_mix_report "$v" "${lim%%$'\t'*}" "${lim#*$'\t'}"
  done
  _spl_lane_mix_share
}

# _spl_lane_mix_next <vendor> -> the first vendor there after it down the
# chain grok|mistral -> agy -> claude (qwen -> claude), else nothing
_spl_lane_mix_next() {
  local v
  case "$1" in grok|mistral) set -- agy claude ;; agy|qwen) set -- claude ;; *) return 0 ;; esac
  for v in "$@"; do [[ "${_LM_AVAIL[$v]}" == yes ]] && { echo "$v"; return 0; }; done
  return 0
}

# _spl_lane_mix_share -> _LM_EFF, _LM_SHARE_TO[<vendor>]: a skipped vendor's
# share goes down the chain (_spl_lane_mix_next); with nothing there down it,
# to the vendors that are there, in proportion to their own shares (the
# rounding to the largest)
_spl_lane_mix_share() {
  local v to skipped=0 on=0 given=0 top=""
  declare -gA _LM_SHARE_TO=()
  for v in "${LANE_MIX_VENDORS[@]}"; do
    [[ "${_LM_AVAIL[$v]}" == yes ]] || { _LM_EFF[$v]=0; continue; }
    _LM_EFF[$v]="${_LM_TGT[$v]}"; on=$(( on + _LM_TGT[$v] ))
    [[ -z "$top" ]] || (( _LM_TGT[$v] > _LM_TGT[$top] )) && top="$v"
  done
  for v in "${LANE_MIX_VENDORS[@]}"; do
    [[ "${_LM_AVAIL[$v]}" == yes ]] && continue
    to="$(_spl_lane_mix_next "$v")"
    if [[ -n "$to" ]]; then _LM_SHARE_TO[$v]="$to"; _LM_EFF[$to]=$(( _LM_EFF[$to] + _LM_TGT[$v] ))
    else _LM_SHARE_TO[$v]="the others"; skipped=$(( skipped + _LM_TGT[$v] )); fi
  done
  (( skipped > 0 )) && [[ -n "$top" ]] || return 0
  for v in "${LANE_MIX_VENDORS[@]}"; do
    [[ "${_LM_AVAIL[$v]}" == yes && "$on" -gt 0 ]] || continue
    _LM_EFF[$v]=$(( _LM_EFF[$v] + skipped * _LM_TGT[$v] / on )); given=$(( given + skipped * _LM_TGT[$v] / on ))
  done
  _LM_EFF[$top]=$(( _LM_EFF[$top] + skipped - given ))
}

# _spl_lane_mix_instance -> _LM_INST (the hub's `fleet-load get` JSON) or
# _LM_INST_WHY (why it was not read), and the `instance:` line
_spl_lane_mix_instance() {
  local out log last
  _LM_INST="" _LM_INST_WHY=""
  if [[ "${LANE_MIX_INSTANCE:-1}" == 0 ]]; then _LM_INST_WHY="LANE_MIX_INSTANCE=0"
  else
    [[ -n "${ENV:-}" ]] && export LANE_ENV="$ENV"  # spl_lane_init reads it
    log="$(mktemp)"
    if ! spl_lane_init >"$log" 2>&1; then last="$(tail -n 1 "$log")"; _LM_INST_WHY="no hub client: ${last:0:160}"
    elif [[ "$LANE_MODE" != hub ]]; then _LM_INST_WHY="no fleet: LANE_FLEET / lease.conf LEASE_FLEET unset"
    else
      out="$(LANE_TIMEOUT="${LANE_MIX_HUB_TIMEOUT:-15}" spl_lane_spool fleet-load get 2>&1)"
      if jq -e '.agent_kinds_off | type == "array"' >/dev/null 2>&1 <<<"$out"; then _LM_INST="$out"
      else last="$(tail -n 1 <<<"$out")"; _LM_INST_WHY="the hub did not answer it: ${last:0:160}"; fi
    fi
    rm -f "$log"
  fi
  if [[ -n "$_LM_INST" ]]; then
    jq -r '"instance: kinds off \(.agent_kinds_off | if length > 0 then join(",") else "none" end), paused \((.agent_kinds_paused // {}) | to_entries | if length > 0 then map("\(.key) until \(.value.until)") | join(", ") else "none" end) (hub)"' <<<"$_LM_INST"
  else
    printf 'instance: setting not read (%s): local checks only\n' "$_LM_INST_WHY"
  fi
}

# _spl_lane_mix_inst_off <vendor> -> why the instance setting keeps it off
# (switched off, or paused), else nothing
_spl_lane_mix_inst_off() {
  [[ -n "$_LM_INST" ]] || return 0
  jq -r --arg k "$1" '((.agent_kinds_paused // {})[$k]) as $p
    | if (.agent_kinds_off | index($k)) != null then "\($k) off in instance settings"
      elif $p != null then "\($k) paused in instance settings until \($p.until): \($p.reason) (box \($p.box))"
      else empty end' <<<"$_LM_INST"
}

# _spl_lane_mix_report <vendor> <verdict-epoch> <verdict> -> a fresh local
# limit verdict reported to the hub as a pause of that vendor for every box,
# until the verdict runs out here (LANE_MIX_LIMIT_FRESH)
_spl_lane_mix_report() {
  [[ -n "$_LM_INST" && "${LANE_MIX_REPORT:-1}" != 0 ]] || return 0
  local until out last
  until="$(date -u -d "@$(( $2 + ${LANE_MIX_LIMIT_FRESH:-21600} ))" +%Y-%m-%dT%H:%M:%SZ)"
  if out="$(LANE_TIMEOUT="${LANE_MIX_HUB_TIMEOUT:-15}" spl_lane_spool fleet-load pause "$1" "$until" "usage limit: $3" 2>&1)"; then
    printf 'instance: %s paused for every box until %s (reported: usage limit: %s)\n' "$1" "$until" "$3"
  else
    last="$(tail -n 1 <<<"$out")"
    printf 'WARN instance: the %s pause did not reach the hub: %s\n' "$1" "${last:0:160}"
  fi
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
    if [[ "${_LM_AVAIL[$v]}" != yes ]]; then st="skip (${_LM_AVAIL[$v]}); share to ${_LM_SHARE_TO[$v]}"
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
  for v in grok mistral agy qwen claude; do
    (( _LM_EFF[$v] > 0 )) || continue
    d=$(( _LM_EFF[$v] - _LM_PCT[$v] ))
    if (( d > _LM_TOL && d > best )); then _LM_EASY="$v" best="$d"; fi
  done
  if [[ -n "$_LM_EASY" ]]; then
    _LM_EASY_WHY="$_LM_EASY is ${best} points under its ${_LM_EFF[$_LM_EASY]}% (band $_LM_TOL)"
    return 0
  fi
  best=0
  for v in grok mistral agy qwen; do (( _LM_EFF[$v] > best )) && { _LM_EASY="$v"; best="${_LM_EFF[$v]}"; }; done
  _LM_EASY_WHY="mix inside the band; easy work goes to the largest non-claude share"
  if [[ -z "$_LM_EASY" ]]; then
    _LM_EASY_WHY="no other vendor is there on this box"
    [[ "${_LM_AVAIL[claude]}" == yes ]] && _LM_EASY=claude
  fi
  return 0
}

# _spl_lane_mix_pick <vendor|hold> <reason> -> the pick line; a reason says
# when the instance setting was not read
_spl_lane_mix_pick() {
  local l="/$1-spawn" why="$2"
  [[ "$1" == hold ]] && l=-
  [[ -z "$_LM_INST_WHY" ]] || why="$why; instance setting not read ($_LM_INST_WHY), local checks only"
  printf 'pick=%s launcher=%s reason=%s\n' "$1" "$l" "$why"
}

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

# _spl_lane_mix_cli <vendor> <user> <home> <cnf> -> "yes", or why it is skipped.
# The binary is named after the vendor, except mistral's: vibe (spec 110 2.1).
_spl_lane_mix_cli() {
  local v="$1" user="$2" home="$3" var bin marker name="$1"
  [[ "$v" == mistral ]] && name=vibe
  var="${v^^}_BIN"
  bin="${!var:-$home/.local/bin/$name}"
  [[ "$bin" == /* ]] || bin="$(command -v "$bin" 2>/dev/null)"
  [[ -n "$bin" ]] && _spl_lane_mix_test "$user" -x "$bin" || { echo "no $v cli"; return; }
  marker="$(yq -r ".env.box.agent_split.auth_marker.$v // \"\"" "$4")"
  [[ -z "$marker" ]] || _spl_lane_mix_test "$user" -e "$home/$marker" || { echo "$v not signed in"; return; }
  echo yes
}

# _spl_lane_mix_limit <vendor> <spool-root> <registry> -> "<epoch>\t<id> S2
# kind=limit <age> ago" for the newest watchdog verdict (ctx*/<id>/out.s2) within
# LANE_MIX_LIMIT_FRESH s on one of that vendor's lanes, else nothing. The
# vendor is the id's registry kind, else its prefix (spec 061: c g a q; spec
# 110: m).
_spl_lane_mix_limit() {
  local hit
  hit="$(_spl_lane_mix_verdict limit "$1" "$2" "$3" "${LANE_MIX_LIMIT_FRESH:-21600}")"
  [[ -z "$hit" ]] || printf '%s\t%s\n' "${hit%%:*}" "${hit#*$'\t'}"
}

# _spl_lane_mix_auth <vendor> <spool-root> <registry> <user> <home> <cnf> ->
# "<id> S2 kind=auth <age> ago" for the newest dead-key verdict (spec 110 2.5:
# a lane in agent-state `auth`, the watchdog's S2 kind=auth) on one of that
# vendor's lanes within LANE_MIX_AUTH_FRESH s, unless its auth marker is newer
# than the verdict (the owner re-keyed since), else nothing
_spl_lane_mix_auth() {
  local hit f marker
  hit="$(_spl_lane_mix_verdict auth "$1" "$2" "$3" "${LANE_MIX_AUTH_FRESH:-604800}")"
  [[ -n "$hit" ]] || return 0
  f="${hit%%$'\t'*}"; f="${f#*:}"
  marker="$(yq -r ".env.box.agent_split.auth_marker.$1 // \"\"" "$6")"
  [[ -n "$marker" ]] && _spl_lane_mix_test "$4" "$5/$marker" -nt "$f" && return 0
  echo "${hit#*$'\t'}"
}

# _spl_lane_mix_verdict <kind> <vendor> <spool-root> <registry> <fresh-s> ->
# "<epoch>:<file>\t<id> S2 kind=<kind> <age> ago" for the newest watchdog
# verdict (ctx*/<id>/out.s2) of that kind within <fresh-s> on one of that
# vendor's lanes, else nothing
_spl_lane_mix_verdict() {
  local want="$1" v="$2" wd="${LANE_MIX_WD_DIR:-$3/dispatch/wd}" fresh="$5"
  local now f t id k best=-1 bestf="" hit=""
  now="$(date +%s)"
  for f in "$wd"/ctx*/*/out.s2; do
    grep -q "^HIT S2 kind=$want" "$f" 2>/dev/null || continue
    t="$(stat -c %Y "$f" 2>/dev/null)" || continue
    (( now - t <= fresh && t > best )) || continue
    id="$(basename "$(dirname "$f")")"
    k="$(awk -F'\t' -v i="$id" '$1 == i {k = $2} END {print k}' "$4" 2>/dev/null)"
    [[ -n "$k" ]] || case "${id:0:2}" in c-) k=claude ;; g-) k=grok ;; a-) k=agy ;; q-) k=qwen ;; m-) k=mistral ;; esac
    [[ "$k" == "$v" ]] || continue
    best="$t" bestf="$f" hit="$id S2 kind=$want $(( (now - t) / 60 ))m ago"
  done
  [[ -z "$hit" ]] || printf '%s:%s\t%s\n' "$best" "$bestf" "$hit"
}

#!/bin/bash
#------------------------------------------------------------------------------
# @description The vendor the next lane spawn should go to, by task kind (spec
# @description 115). Each kind has its own row of vendor weights out of 100
# @description and a backup, cnf env.box.agent_split_by_kind (all.env.yaml) or
# @description LANE_MIX_SPLIT_KIND (do_spl_agent_split_show --kind); the main
# @description is the vendor with the highest weight. APPROXIMATE, never a quota.
# @description Kinds: specs_and_docs, tests, simple_coding, complex_coding,
# @description i18n, secret. The old names stay as aliases: spec is
# @description specs_and_docs, hard is complex_coding, default is
# @description simple_coding. No kind: difficulty >= 60 is complex_coding,
# @description else simple_coding. LANE_MIX_SENSITIVE=1 makes any kind secret.
# @description The one rule (spec 115 section 5): the candidates are the main,
# @description then the backup, then claude, the default and last fallback.
# @description The pick is the first one that is available and has failed
# @description fewer than LANE_MIX_TRIES_MAX (2) tries on this task
# @description (LANE_MIX_TASK, read from the tries journal,
# @description spl-lane-mix-journal.func.sh). With no try on the task yet, the
# @description per-kind nudge comes first: the vendor of the row furthest below
# @description its weight by MORE than the tolerance, over the last `window`
# @description spawns of that kind in $SPOOL_ROOT/registry.tsv (the kind is the
# @description row's last column; a row with none counts as simple_coding).
# @description A vendor that is out is skipped at once, with no 2-try wait, and
# @description its weight goes to the row's backup, else to claude: its CLI is
# @description not installed, the cnf auth_marker is absent from the agent
# @description user's home, the watchdog saw one of its lanes on an S2
# @description kind=limit screen within LANE_MIX_LIMIT_FRESH s (spec 102 T029),
# @description or an S2 kind=auth verdict within LANE_MIX_AUTH_FRESH s newer
# @description than its auth marker (spec 110 2.5). An S2 verdict is never a
# @description failed try.
# @description The instance setting (rdb 0149, owner HUM-10 t1 41fa1f2d) beats
# @description all of it, on every box: a vendor switched off or paused on the
# @description Fleet load page is out in every kind. It is read from the hub
# @description (`spool fleet-load get`); a hub that does not answer, or no
# @description fleet, -> the local checks only, said in every reason. The one
# @description write: a fresh local limit verdict is reported to the hub as a
# @description pause of that vendor until the verdict runs out
# @description (`spool fleet-load pause`), so every box skips it.
# @description Data rule: kind secret goes to claude or mistral only, never
# @description agy, grok or qwen; both out or exhausted -> pick=hold. Language
# @description rule: i18n goes to agy; served by anyone else the pick carries
# @description flag=needs_agy_review and the text waits for an agy review.
# @description Prints the kind's table, then `pick=<vendor> launcher=/<vendor>-spawn
# @description kind=<k> reason=...`, or `pick=hold`.
# @param LANE_MIX_KIND (optional) - a kind or an alias above; unset reads the difficulty
# @param LANE_MIX_DIFFICULTY (optional) - 0..100, the task against your own capacity
# @param LANE_MIX_SENSITIVE (optional) - 1: the work carries secrets/personal data
# @param LANE_MIX_TASK (optional) - the task_id: its failed tries pick the backup
# @param LANE_MIX_SPLIT_KIND (optional) - "claude=N grok=N agy=N qwen=N mistral=N
# @param   backup=<vendor>", the kind's row (do_spl_agent_split_show --kind);
# @param   overrides the cnf row. LANE_MIX_SPLIT is read the same way when it is
# @param   unset; a line without backup keeps the cnf backup, one without
# @param   mistral reads mistral=0
# @param LANE_MIX_CNF (optional) - default <checkout>/csi-spl-cnf/csi-spl/all.env.yaml
# @param LANE_MIX_REGISTRY (optional) - default $SPOOL_ROOT/registry.tsv
# @param LANE_MIX_JOURNAL (optional) - the tries journal files (spl-lane-mix-journal.func.sh)
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
# @example LANE_MIX_KIND=simple_coding LANE_MIX_TASK=<task_id> ./run -a do_spl_lane_mix
# @example LANE_MIX_KIND=specs_and_docs ./run -a do_spl_lane_mix
# @example LANE_MIX_KIND=i18n ./run -a do_spl_lane_mix
# @example LANE_MIX_DIFFICULTY=70 ./run -a do_spl_lane_mix
# @example LANE_MIX_DIFFICULTY=30 LANE_MIX_SENSITIVE=1 ./run -a do_spl_lane_mix
#------------------------------------------------------------------------------
LANE_MIX_VENDORS=(claude grok agy qwen mistral)
# spec 115 section 5 (owner t1 b1ab562b msg fb9e228c): the backup takes over
# after two failed tries of the main on the same task
LANE_MIX_TRIES_MAX=2

do_spl_lane_mix() {
  do_require_bin yq || return 1
  local root="${SPOOL_ROOT:-/var/spool-hub}" org_app
  [[ "$(basename "${PROJ_PATH:?PROJ_PATH unset}")" =~ ^([a-z]+-[a-z]+)-orc$ ]] || {
    do_log "FATAL cannot read <org>-<app> from $PROJ_PATH"; return 1; }
  org_app="${BASH_REMATCH[1]}"
  local cnf="${LANE_MIX_CNF:-$APP_PATH/$org_app-cnf/$org_app/all.env.yaml}"
  local reg="${LANE_MIX_REGISTRY:-$root/registry.tsv}"
  local diff="${LANE_MIX_DIFFICULTY:-}" sens="${LANE_MIX_SENSITIVE:-0}"
  [[ -r "$cnf" ]] || { do_log "FATAL no cnf $cnf"; return 1; }
  [[ -z "$diff" || ( "$diff" =~ ^[0-9]{1,3}$ && "$diff" -le 100 ) ]] || {
    do_log "FATAL LANE_MIX_DIFFICULTY must be 0..100, got '$diff'"; return 1; }
  [[ "$sens" =~ ^[01]$ ]] || { do_log "FATAL LANE_MIX_SENSITIVE must be 0 or 1, got '$sens'"; return 1; }
  [[ "${LANE_MIX_LIMIT_FRESH:-0}" =~ ^[0-9]+$ ]] || {
    do_log "FATAL LANE_MIX_LIMIT_FRESH must be whole seconds, got '$LANE_MIX_LIMIT_FRESH'"; return 1; }
  [[ "${LANE_MIX_AUTH_FRESH:-0}" =~ ^[0-9]+$ ]] || {
    do_log "FATAL LANE_MIX_AUTH_FRESH must be whole seconds, got '$LANE_MIX_AUTH_FRESH'"; return 1; }
  _spl_lane_mix_kind "${LANE_MIX_KIND:-}" "$diff" "$sens" || return 1

  declare -gA _LM_TGT=() _LM_EFF=() _LM_CNT=() _LM_PCT=() _LM_AVAIL=() _LM_TRIED=() _LM_FAILS=()
  _spl_lane_mix_target "$cnf" || return 1
  _spl_lane_mix_instance
  _spl_lane_mix_avail "$root" "$cnf" "$reg"
  _spl_lane_mix_actual "$reg"
  _spl_lane_mix_journal "$root" "${LANE_MIX_TASK:-}"
  _spl_lane_mix_table "$cnf" "$reg"
  case "$_LM_KIND" in
    secret) _spl_lane_mix_secret ;;
    # owner HUM-10 t1 296582df (2026-10-08): agy has the final word on any
    # user-facing text in several languages
    i18n) _spl_lane_mix_want agy "kind i18n: agy has the final word on multilingual text" ;;
    *) _spl_lane_mix_want "$_LM_MAIN" "kind $_LM_KIND: main $_LM_MAIN, backup $_LM_BACKUP" ;;
  esac
}

# _spl_lane_mix_kind <kind> <difficulty> <sensitive> -> _LM_KIND, _LM_KIND_WHY:
# the spec 115 name (aliases resolved), or a FATAL for an unknown kind
_spl_lane_mix_kind() {
  _LM_KIND_WHY="LANE_MIX_KIND=$1"
  case "$1" in
    specs_and_docs|tests|simple_coding|complex_coding|i18n|secret) _LM_KIND="$1" ;;
    spec) _LM_KIND=specs_and_docs ;;
    hard) _LM_KIND=complex_coding ;;
    default) _LM_KIND=simple_coding ;;
    "") if [[ -n "$2" ]] && (( $2 >= 60 )); then _LM_KIND=complex_coding _LM_KIND_WHY="difficulty $2 >= 60"
        else _LM_KIND=simple_coding _LM_KIND_WHY="difficulty ${2:-unset} < 60"; fi ;;
    *) do_log "FATAL LANE_MIX_KIND must be specs_and_docs, tests, simple_coding, complex_coding, i18n or secret (or spec, hard, default), got '$1'"
       return 1 ;;
  esac
  [[ "$3" == 1 ]] || return 0
  _LM_KIND_WHY="LANE_MIX_SENSITIVE=1"
  _LM_KIND=secret
}

# _spl_lane_mix_target <cnf> -> _LM_TGT, _LM_MAIN, _LM_BACKUP, _LM_ROW (where
# the row came from), _LM_TOL, _LM_WIN: the kind's row from cnf, or from
# LANE_MIX_SPLIT_KIND (else LANE_MIX_SPLIT), checked by _spl_lane_mix_row_check
_spl_lane_mix_target() {
  local cnf="$1" v line="${LANE_MIX_SPLIT_KIND:-${LANE_MIX_SPLIT:-}}"
  local re='^claude=([0-9]+) grok=([0-9]+) agy=([0-9]+) qwen=([0-9]+)( mistral=([0-9]+))?( backup=([a-z]+))?$'
  _LM_TOL="$(yq -r '.env.box.agent_split.tolerance // 5' "$cnf")"
  _LM_WIN="$(yq -r '.env.box.agent_split.window // 20' "$cnf")"
  for v in "${LANE_MIX_VENDORS[@]}"; do
    _LM_TGT[$v]="$(yq -r ".env.box.agent_split_by_kind.$_LM_KIND.$v // 0" "$cnf")"
  done
  _LM_BACKUP="$(yq -r ".env.box.agent_split_by_kind.$_LM_KIND.backup // \"\"" "$cnf")"
  _LM_ROW="cnf env.box.agent_split_by_kind.$_LM_KIND"
  if [[ -n "$line" ]]; then
    [[ "$line" =~ $re ]] || {
      do_log "FATAL LANE_MIX_SPLIT_KIND must read 'claude=N grok=N agy=N qwen=N mistral=N backup=<vendor>', got '$line'"; return 1; }
    _LM_TGT[claude]="${BASH_REMATCH[1]}" _LM_TGT[grok]="${BASH_REMATCH[2]}"
    _LM_TGT[agy]="${BASH_REMATCH[3]}" _LM_TGT[qwen]="${BASH_REMATCH[4]}"
    _LM_TGT[mistral]="${BASH_REMATCH[6]:-0}"
    _LM_BACKUP="${BASH_REMATCH[8]:-$_LM_BACKUP}"
    _LM_ROW="$([[ -n "${LANE_MIX_SPLIT_KIND:-}" ]] && echo LANE_MIX_SPLIT_KIND || echo LANE_MIX_SPLIT)"
  fi
  [[ "$_LM_TOL" =~ ^[0-9]{1,2}$ && "$_LM_WIN" =~ ^[0-9]{1,3}$ && "$_LM_WIN" -gt 0 ]] || {
    do_log "FATAL agent_split tolerance/window must be whole numbers, got '$_LM_TOL'/'$_LM_WIN'"; return 1; }
  _spl_lane_mix_row_check
}

# _spl_lane_mix_row_check -> _LM_MAIN, or a FATAL for a row that breaks the
# spec 115 section 2 rules: whole numbers summing to 100, one strict maximum
# (the main), a known backup other than the main, agy 0 and never the backup
# in a coding kind, only claude or mistral in secret
_spl_lane_mix_row_check() {
  local v sum=0 top=-1 ties=0 at="agent_split_by_kind.$_LM_KIND ($_LM_ROW)"
  _LM_MAIN=""
  for v in "${LANE_MIX_VENDORS[@]}"; do
    [[ "${_LM_TGT[$v]}" =~ ^[0-9]{1,3}$ ]] || { do_log "FATAL $at.$v must be a whole number, got '${_LM_TGT[$v]}'"; return 1; }
    sum=$(( sum + _LM_TGT[$v] ))
    if (( _LM_TGT[$v] > top )); then top="${_LM_TGT[$v]}" _LM_MAIN="$v" ties=0
    elif (( _LM_TGT[$v] == top )); then ties=1; fi
  done
  (( sum == 100 )) || { do_log "FATAL $at sums to $sum, not 100"; return 1; }
  (( ties == 0 )) || { do_log "FATAL $at has a tied main at $top: one vendor must hold the strict maximum"; return 1; }
  [[ " ${LANE_MIX_VENDORS[*]} " == *" $_LM_BACKUP "* && "$_LM_BACKUP" != "$_LM_MAIN" ]] || {
    do_log "FATAL $at backup must be a vendor other than the main $_LM_MAIN, got '$_LM_BACKUP'"; return 1; }
  case "$_LM_KIND" in
    tests|simple_coding|complex_coding)
      (( _LM_TGT[agy] == 0 )) && [[ "$_LM_BACKUP" != agy ]] || {
        do_log "FATAL $at: agy writes no code (spec 115 G2), agy=${_LM_TGT[agy]} backup=$_LM_BACKUP"; return 1; } ;;
    secret)
      (( _LM_TGT[grok] + _LM_TGT[agy] + _LM_TGT[qwen] == 0 )) && [[ "$_LM_BACKUP" =~ ^(claude|mistral)$ ]] || {
        do_log "FATAL $at: the data rule allows claude or mistral only, backup=$_LM_BACKUP"; return 1; } ;;
  esac
  return 0
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

# _spl_lane_mix_heir <vendor> -> where an out vendor's weight goes: the row's
# backup when it is there, else claude when it is there, else nothing
_spl_lane_mix_heir() {
  local v
  for v in "$_LM_BACKUP" claude; do
    [[ "$v" != "$1" && "${_LM_AVAIL[$v]}" == yes ]] && { echo "$v"; return 0; }
  done
  return 0
}

# _spl_lane_mix_share -> _LM_EFF, _LM_SHARE_TO[<vendor>]: the row's weights,
# with an out vendor's weight given to its heir (spec 115 section 3.3)
_spl_lane_mix_share() {
  local v to
  declare -gA _LM_SHARE_TO=()
  for v in "${LANE_MIX_VENDORS[@]}"; do
    [[ "${_LM_AVAIL[$v]}" == yes ]] && _LM_EFF[$v]="${_LM_TGT[$v]}" || _LM_EFF[$v]=0
  done
  for v in "${LANE_MIX_VENDORS[@]}"; do
    [[ "${_LM_AVAIL[$v]}" == yes ]] && continue
    to="$(_spl_lane_mix_heir "$v")"
    _LM_SHARE_TO[$v]="${to:-nobody}"
    [[ -n "$to" ]] && _LM_EFF[$to]=$(( _LM_EFF[$to] + _LM_TGT[$v] ))
  done
  return 0
}

# _spl_lane_mix_choose <main> [<allowed vendors>] -> _LM_CHOICE (a vendor or
# hold), _LM_CHOICE_WHY. The one rule of spec 115 section 5: with no try on
# the task, the per-kind nudge first; then main, backup, claude, the first
# that is available and has failed fewer than LANE_MIX_TRIES_MAX tries on
# this task. <allowed> narrows every path (the data rule).
_spl_lane_mix_choose() {
  local main="$1" allow="${2:-}" v role seen=" " why order=()
  for v in "$main" "$_LM_BACKUP" claude; do
    [[ "$seen" == *" $v "* ]] && continue
    seen+="$v "
    [[ -z "$allow" || " $allow " == *" $v "* ]] && order+=("$v")
  done
  if (( _LM_TRIES == 0 )); then
    _spl_lane_mix_easy
    if [[ -n "$_LM_EASY" && ( -z "$allow" || " $allow " == *" $_LM_EASY "* ) ]]; then
      _LM_CHOICE="$_LM_EASY" _LM_CHOICE_WHY="no try on this task yet: $_LM_EASY_WHY"; return 0
    fi
    why="no try on this task yet, $_LM_EASY_WHY"
  else
    why="$_LM_TRIES tries on task $LANE_MIX_TASK"
  fi
  for v in "${order[@]}"; do
    if [[ "${_LM_AVAIL[$v]}" != yes ]]; then why+="; $v is out (${_LM_AVAIL[$v]})"; continue; fi
    if (( ${_LM_FAILS[$v]:-0} >= LANE_MIX_TRIES_MAX )); then
      why+="; $v failed ${_LM_FAILS[$v]} tries on this task"; continue
    fi
    role="the main"
    [[ "$v" == "$main" ]] || role="the backup"
    [[ "$v" == "$main" || "$v" == "$_LM_BACKUP" ]] || role="the last fallback"
    _LM_CHOICE="$v" _LM_CHOICE_WHY="$why; $v is $role"
    return 0
  done
  _LM_CHOICE=hold _LM_CHOICE_WHY="$why; no candidate is left"
}

# _spl_lane_mix_want <main> <reason> -> the pick line of the one rule; an
# i18n pick other than agy carries flag=needs_agy_review (language rule)
_spl_lane_mix_want() {
  local flag=""
  _spl_lane_mix_choose "$1"
  if [[ "$_LM_CHOICE" == hold ]]; then
    _spl_lane_mix_pick hold "$2; $_LM_CHOICE_WHY: queue the work and send a blocker to the orchestrator"
    return 0
  fi
  if [[ "$_LM_KIND" == i18n && "$_LM_CHOICE" != agy ]]; then
    flag=needs_agy_review
    _LM_CHOICE_WHY+="; the text waits for an agy review before it ships"
  fi
  _spl_lane_mix_pick "$_LM_CHOICE" "$2; $_LM_CHOICE_WHY" "$flag"
}

# _spl_lane_mix_secret -> the pick line under the data rule (global CLAUDE.md
# "Spawn an agent", spec 110 D2, spec 115 section 5): secrets and personal
# data go to claude or mistral only, in every path; both out or exhausted ->
# hold, never agy, grok or qwen
_spl_lane_mix_secret() {
  _spl_lane_mix_choose "$_LM_MAIN" "claude mistral"
  case "$_LM_CHOICE" in
    claude) _spl_lane_mix_pick claude "data rule: secrets or personal data go to claude or mistral only; $_LM_CHOICE_WHY" ;;
    mistral) _spl_lane_mix_pick mistral "data rule: secrets or personal data go to claude or mistral only; $_LM_CHOICE_WHY" ;;
    *) _spl_lane_mix_pick hold "data rule: secrets or personal data go to claude or mistral only, and neither may take it; $_LM_CHOICE_WHY: queue the work and send a blocker to the orchestrator" ;;
  esac
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
# spawns of this kind, one row per id (its latest), role seats 001..003 out.
# The kind is the row's last column; a row with none is simple_coding.
_spl_lane_mix_actual() {
  local v vendor
  _LM_N=0
  for v in "${LANE_MIX_VENDORS[@]}"; do _LM_CNT[$v]=0; done
  if [[ -r "$1" ]]; then
    while read -r vendor; do
      [[ -n "${_LM_CNT[$vendor]+x}" ]] || continue
      _LM_CNT[$vendor]=$(( _LM_CNT[$vendor] + 1 )); _LM_N=$(( _LM_N + 1 ))
    done < <(awk -F'\t' -v want="$_LM_KIND" '
               $1 !~ /-00[1-3]$/ && NF >= 5 {
                 k[$1] = $2; t[$1] = $5
                 kd[$1] = ($NF ~ /^(specs_and_docs|tests|simple_coding|complex_coding|i18n|secret)$/) ? $NF : "simple_coding"
               }
               END { for (i in k) if (kd[i] == want) print t[i] "\t" k[i] }' "$1" |
             sort | tail -n "$_LM_WIN" | cut -f2)
  fi
  for v in "${LANE_MIX_VENDORS[@]}"; do
    _LM_PCT[$v]=$(( _LM_N > 0 ? (_LM_CNT[$v] * 100 + _LM_N / 2) / _LM_N : 0 ))
  done
}

# _spl_lane_mix_table <cnf> <registry> -> the kind, its row vs its actual mix,
# and the task's tries
_spl_lane_mix_table() {
  local v st tries=""
  printf 'kind=%s (%s) main=%s backup=%s row=%s\n' "$_LM_KIND" "$_LM_KIND_WHY" "$_LM_MAIN" "$_LM_BACKUP" "$_LM_ROW"
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
  if [[ -z "${LANE_MIX_TASK:-}" ]]; then echo "journal: no LANE_MIX_TASK, no try counted"; return 0; fi
  for v in "${LANE_MIX_VENDORS[@]}"; do
    [[ -n "${_LM_TRIED[$v]:-}" ]] && tries+=" $v=${_LM_TRIED[$v]}/${_LM_FAILS[$v]:-0}"
  done
  printf 'journal: task=%s tries=%s (vendor=tries/failed:%s) backup after %s failed\n' \
    "$LANE_MIX_TASK" "$_LM_TRIES" "${tries:- none}" "$LANE_MIX_TRIES_MAX"
}

# _spl_lane_mix_easy -> _LM_EASY, _LM_EASY_WHY: the per-kind nudge (spec 115
# section 2.1), the vendor furthest below its effective weight by more than
# the tolerance, else nothing (the main takes it)
_spl_lane_mix_easy() {
  local v d best=-1
  _LM_EASY=""
  for v in "${LANE_MIX_VENDORS[@]}"; do
    (( _LM_EFF[$v] > 0 )) || continue
    d=$(( _LM_EFF[$v] - _LM_PCT[$v] ))
    if (( d > _LM_TOL && d > best )); then _LM_EASY="$v" best="$d"; fi
  done
  if [[ -n "$_LM_EASY" ]]; then
    _LM_EASY_WHY="$_LM_EASY is ${best} points under its ${_LM_EFF[$_LM_EASY]}% of $_LM_KIND (band $_LM_TOL)"
  else
    _LM_EASY_WHY="the $_LM_KIND mix is inside the band"
  fi
  return 0
}

# _spl_lane_mix_pick <vendor|hold> <reason> [<flag>] -> the pick line; a
# reason says when the instance setting was not read
_spl_lane_mix_pick() {
  local l="/$1-spawn" why="$2" flag=""
  [[ "$1" == hold ]] && l=-
  [[ -n "${3:-}" ]] && flag=" flag=$3"
  [[ -z "$_LM_INST_WHY" ]] || why="$why; instance setting not read ($_LM_INST_WHY), local checks only"
  printf 'pick=%s launcher=%s kind=%s%s reason=%s\n' "$1" "$l" "$_LM_KIND" "$flag" "$why"
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

#!/bin/bash
#------------------------------------------------------------------------------
# @description The weekly limit alert (SPL-2403, SPL-3849; owner HUM-10, t1
# @description 6e02f297 msgs a86644f7 + 3c2d94f0): a non-intelligence check,
# @description run from cron on every box (box-crons manifest row
# @description weekly-limit-alert), no agent session. It reads THIS box's weekly
# @description used % per agent kind with the box pick's own reader
# @description (spl_box_quota_here: the claude banner and transcripts, the grok
# @description footer and limit screen; no new probe) and, when a kind's % crosses
# @description 90, 95 or 99, posts ONE line in the #alerts channel (the one the
# @description asks timer posts in): box, kind, %, the reset time when the banner
# @description names one. Each threshold once per kind per box per reset week:
# @description the state file keeps the highest threshold posted and the reset,
# @description so a tick at the same % posts nothing. A jump over two thresholds
# @description posts one line, for the higher. It re-arms when the reset time has
# @description passed, or when a reading falls below the lowest threshold (the
# @description week reset; grok names no reset time). A kind with no reading
# @description (no banner, a reset passed) is "no reading", never 0: it neither
# @description posts nor re-arms. Every tick ends with one summary line naming
# @description every kind. Dry run unless DRY_RUN=0 (prints the line, writes no
# @description state). A post that fails is not recorded: retried next tick.
# @param WEEKLY_ALERT_PCTS (optional) - the thresholds, ascending, space-separated, default "90 95 99"
# @param WEEKLY_ALERT_KINDS (optional) - the kinds named in the summary, default "claude grok mistral agy qwen"
# @param WEEKLY_ALERT_STATE (optional) - the state file, default $XDG_STATE_HOME/csi-spl/weekly-limit-alert.tsv
# @param WEEKLY_ALERT_AGENT (optional) - the post's author, default LEASE_ORCH of the dispatch lease.conf
# @param WEEKLY_ALERT_CMD (optional, tests) - replaces the #alerts post: the line on stdin, exit 0 = posted
# @param LANE_QUOTA_CMD (optional, tests) - the reading, as spl_box_quota_here prints it ("claude:96@<epoch>,grok:91")
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_weekly_limit_alert
# @example DRY_RUN=0 ./run -a do_spl_weekly_limit_alert
#------------------------------------------------------------------------------
do_spl_weekly_limit_alert() {
  local dry="${DRY_RUN:-1}" pcts="${WEEKLY_ALERT_PCTS:-90 95 99}" kinds="${WEEKLY_ALERT_KINDS:-claude grok mistral agy qwen}"
  local st="${WEEKLY_ALERT_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/csi-spl/weekly-limit-alert.tsv}"
  local wk now k v pct reset sum="" posted=0
  local -A read_pct=() read_at=() fired=() rst=()
  [[ "$dry" == 0 || "$dry" == 1 ]] || { do_log "FATAL DRY_RUN must be 0 or 1, got: '$dry'"; return 1; }
  [[ "$pcts" =~ ^[0-9]{1,3}( [0-9]{1,3})*$ ]] || { do_log "FATAL WEEKLY_ALERT_PCTS must be whole % separated by one space, got: '$pcts'"; return 1; }
  spl_lane_init || return 1
  declare -F spl_box_quota_here >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-box-quota.func.sh"
  now="$(date +%s)"
  wk="$(BOX_QUOTA_RESET=1 spl_box_quota_here)"
  for v in ${wk//,/ }; do
    [[ "$v" =~ ^([a-z]+):([0-9]{1,3})(@([0-9]+))?$ ]] || continue
    read_pct[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}" read_at[${BASH_REMATCH[1]}]="${BASH_REMATCH[4]}"
  done
  if [[ -r "$st" ]]; then
    while IFS=$'\t' read -r k v reset; do
      [[ "$k" =~ ^[a-z]+$ && "$v" =~ ^[0-9]+$ ]] || continue
      fired[$k]="$v" rst[$k]="$reset"
    done <"$st"
  fi
  for k in $kinds "${!read_pct[@]}"; do
    [[ " $sum " == *" $k "* ]] && continue
    sum+="${sum:+ }$k"
  done
  local line="weekly limit on $LANE_BOX:" out
  for k in $sum; do
    spl_weekly_alert_rearm "$k" "$now" "${pcts%% *}"
    pct="${read_pct[$k]:-}"
    if [[ -z "$pct" ]]; then line+=" $k no reading;"; continue; fi
    [[ -n "${read_at[$k]}" ]] && rst[$k]="${read_at[$k]}"
    line+=" $k ${pct}%${fired[$k]:+ (posted ${fired[$k]}%)};"
    v="$(spl_weekly_alert_due "$pct" "${fired[$k]:-0}" "$pcts")"
    [[ -n "$v" ]] || continue
    out="$(spl_weekly_alert_text "$k" "$pct" "$v" "${rst[$k]:-}")"
    if [[ "$dry" == 1 ]]; then
      echo "PLAN post in #alerts: $out"; continue
    fi
    if spl_weekly_alert_post "$out"; then
      fired[$k]="$v" posted=$(( posted + 1 ))
      do_log "ALERT posted in #alerts: $out"
    else
      do_log "WARN the $k ${v}% alert did not post; retried next tick"
    fi
  done
  do_log "INFO ${line%;} ($posted posted)"
  [[ "$dry" == 1 ]] && { do_log "OK DRY_RUN no post, no state written. Re-run with DRY_RUN=0."; return 0; }
  spl_weekly_alert_save "$st"
}

# Re-arm KIND (fired back to none) when its stored reset time has passed, or
# when its reading is below the lowest threshold LOW (the week reset). No
# reading re-arms only by the reset time: absent is never 0.
spl_weekly_alert_rearm() {  # KIND NOW LOW
  local k="$1"
  [[ -n "${fired[$k]:-}" ]] || return 0
  if [[ "${rst[$k]:-}" =~ ^[0-9]+$ ]] && (( $2 >= rst[$k] )); then
    unset "fired[$k]" "rst[$k]"; do_log "INFO $k: the weekly reset passed, the thresholds re-arm"; return 0
  fi
  if [[ -n "${read_pct[$k]:-}" ]] && (( read_pct[$k] < $3 )); then
    unset "fired[$k]" "rst[$k]"; do_log "INFO $k: ${read_pct[$k]}% is below $3%, a new week, the thresholds re-arm"
  fi
  return 0
}

# The threshold to post for PCT, or nothing: the highest of PCTS at or under
# PCT and above FIRED (the highest already posted this week).
spl_weekly_alert_due() {  # PCT FIRED PCTS
  local t due=""
  for t in $3; do (( $1 >= t && t > $2 )) && due="$t"; done
  printf '%s' "$due"
}

# The one #alerts line.
spl_weekly_alert_text() {  # KIND PCT THRESHOLD RESET_EPOCH
  local when="reset time unknown"
  [[ "$4" =~ ^[0-9]+$ ]] && when="resets $(date -u -d "@$4" +%Y-%m-%dT%H:%MZ)"
  printf '**WEEKLY LIMIT** %s on %s: %s%% of its weekly limit used (crossed %s%%), %s. New %s lanes skip a box at %s%%+ (env.box.quota.weekly_max_pct).' \
    "$1" "$LANE_BOX" "$2" "$3" "$when" "$1" "$(spl_box_quota_max "${SPL_CNF:-}")"
}

# The #alerts post (do_spl_desk_post, kind note, as the asks timer posts):
# WEEKLY_ALERT_CMD replaces it; no hub on this machine -> logged, not posted,
# and not recorded, so a box that gets its desk later still posts.
spl_weekly_alert_post() {  # TEXT
  local who="${WEEKLY_ALERT_AGENT:-${LEASE_ORCH:-}}"
  if [[ -n "${WEEKLY_ALERT_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $WEEKLY_ALERT_CMD <<<"$1" >/dev/null
    return
  fi
  if [[ "${LANE_MODE:-}" != hub || -n "${LANE_HUB_CMD:-}" || -z "$who" ]]; then
    do_log "ALERT (not posted: ${who:-no LEASE_ORCH}, mode ${LANE_MODE:-none}): $1"
    return 1
  fi
  ENV="$LANE_ENV" TENANT_ID="$LANE_TENANT" DESK_BOX="$LANE_DESK_BOX" DESK_AGENT="$who" DESK_CHANNEL=alerts \
    DESK_KIND=note DESK_BODY="$1" DRY_RUN=0 do_spl_desk_post >/dev/null 2>&1
}

# The state file: one row per kind with a posted threshold, kind TAB
# threshold TAB reset epoch (empty when unknown). Written whole, atomically.
spl_weekly_alert_save() {  # FILE
  local k
  mkdir -p "$(dirname "$1")" || { do_log "FATAL cannot create the dir of $1"; return 1; }
  for k in "${!fired[@]}"; do printf '%s\t%s\t%s\n' "$k" "${fired[$k]}" "${rst[$k]:-}"; done | sort >"$1.tmp.$$" &&
    mv -f "$1.tmp.$$" "$1" || { rm -f "$1.tmp.$$"; do_log "FATAL cannot write $1"; return 1; }
}

#!/bin/bash
#------------------------------------------------------------------------------
# @description The box map channel-rules.tsv by a named action, never a hand edit
# @description (SPL-5146). The map stays out of git: a channel name can be a
# @description customer's, so its values come from env.
# @description CHANNEL_RULE_CMD=check (default) reads and changes nothing. Exit 0
# @description fine; 2 the map is missing or unreadable (an ALARM) or has a bad or
# @description second row for a channel; 3 stale: older than the floor, holding
# @description nothing, or without a hold named in CHANNEL_RULE_CHECK_WANT. A map
# @description restored with a new mtime that still holds something shows only
# @description through CHANNEL_RULE_CHECK_WANT.
# @description CHANNEL_RULE_CMD=set writes one row, a dry run unless DRY_RUN=0. It
# @description keeps the other rows, the mode and the ACL. Exit 1 a bad value; 2 no
# @description map, and CHANNEL_RULE_CREATE=1 not set (a new map of one row would
# @description free every other channel); 3 the channel has another row, and
# @description CHANNEL_RULE_REPLACE=1 not set.
# @param CHANNEL_RULE_CMD (optional) - check (default) or set
# @param CHANNEL_RULE_TENANT (required for set) - workspace id
# @param CHANNEL_RULE_CHANNEL (required for set) - channel name, or * for the whole workspace
# @param CHANNEL_RULE_DOC (required for set, not for *) - the qto doc uuid of the channel's rules
# @param CHANNEL_RULE_ENV (required for set, not for *) - dev or prd
# @param CHANNEL_RULE_AGENT (required for set, not for *) - the desk agent the export runs as
# @param CHANNEL_RULE_SOLE (optional) - the sole seat, <agent id>@<box>, default -
# @param CHANNEL_RULE_NO_AUTO_POST (optional) - 1: column 7 is no-auto-post; a * row always is
# @param CHANNEL_RULE_REPLACE (optional) - 1 replaces the channel's row
# @param CHANNEL_RULE_CREATE (optional) - 1 creates a missing map
# @param CHANNEL_RULE_CHECK_NOT_BEFORE (optional) - a map older is stale, default 2026-11-07T05:58:00Z
# @param CHANNEL_RULE_CHECK_WANT (optional) - holds that must be there: <tenant> <channel>,...
# @param DRY_RUN (optional) - set only: 1 (default) or 0
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param SPOOL_CHANNEL_RULES_MAP (optional) - default <SPOOL_ROOT>/channel-rules.tsv
# @example ./run -a do_spl_channel_rule
# @example CHANNEL_RULE_CMD=set CHANNEL_RULE_TENANT=<tenant> CHANNEL_RULE_CHANNEL='*' DRY_RUN=0 ./run -a do_spl_channel_rule
#------------------------------------------------------------------------------
do_spl_channel_rule() {
  declare -F cr_map_fault >/dev/null ||
    source "$PROJ_PATH/src/bash/features/spawn-agents/lib/channel-rules.inc.sh" ||
    { do_log "FATAL the channel rules lib cannot be read"; return 1; }
  case "${CHANNEL_RULE_CMD:-check}" in
    check) spl_cr_check ;;
    set) spl_cr_set ;;
    *) do_log "FATAL CHANNEL_RULE_CMD must be check or set, got: ${CHANNEL_RULE_CMD}"; return 1 ;;
  esac
}

# spl_cr_row_why COLUMN...: why these columns are no map row; nothing when they are.
spl_cr_row_why() {
  (( $# >= 5 && $# <= 7 )) || { echo "has $# columns, not 5 to 7"; return; }
  [[ "$1" =~ ^${CR_TENANT_RX}$ ]] || { echo "the workspace is not valid"; return; }
  if [[ "$2" == '*' ]]; then
    [[ "$3$4$5${6:-}" == "----" && "${7:-}" == no-auto-post ]] || echo "a * row is '<workspace> * - - - - no-auto-post'"
    return
  fi
  [[ "$2" =~ ^${CR_CHANNEL_RX}$ ]] || { echo "the channel is not valid"; return; }
  [[ "$3" =~ ^${CR_DOC_RX}$ ]] || { echo "column 3 is not a doc uuid"; return; }
  [[ "$4" =~ ^(dev|prd)$ ]] || { echo "column 4 is not dev or prd"; return; }
  [[ "$5" =~ ^[a-z]-[0-9]{3}$ ]] || { echo "column 5 is not an agent id"; return; }
  [[ "${6:--}" == - || "${6:-}" =~ ^[a-z]-[0-9]{3}@[A-Za-z0-9._-]+$ ]] || { echo "column 6 is not <agent id>@<box> or -"; return; }
  [[ "${7:--}" == - || "${7:-}" == no-auto-post ]] || echo "column 7 is not no-auto-post, - or empty"
}

# spl_cr_rows MAP: SPL_CR_ROWS, SPL_CR_HOLDS and the count of bad rows, one
# FATAL per bad row, by line number: a row's values stay out of the log.
spl_cr_rows() {
  local l n=0 bad=0 why k
  local -a f=()
  local -A seen=()
  SPL_CR_ROWS=0 SPL_CR_HOLDS=0
  while IFS= read -r l || [[ -n "$l" ]]; do
    n=$((n + 1))
    [[ -z "$l" || "$l" == \#* ]] && continue
    IFS=$'\037' read -r -a f <<<"${l//$'\t'/$'\037'}"
    SPL_CR_ROWS=$((SPL_CR_ROWS + 1))
    why="$(spl_cr_row_why "${f[@]}")"
    if [[ -n "$why" ]]; then do_log "FATAL $1 line $n: $why"; bad=$((bad + 1)); continue; fi
    [[ "${f[6]:-}" == no-auto-post ]] && SPL_CR_HOLDS=$((SPL_CR_HOLDS + 1))
    k="${f[0]}"$'\t'"${f[1]}"
    if [[ -n "${seen[$k]:-}" ]]; then do_log "FATAL $1 line $n: a second row for the channel of line ${seen[$k]}"; bad=$((bad + 1)); fi
    seen[$k]="$n"
  done <"$1"
  return "$bad"
}

spl_cr_check() {
  local m fault floor="${CHANNEL_RULE_CHECK_NOT_BEFORE:-2026-11-07T05:58:00Z}" floor_s mt rc=0 w t c
  local -a want=()
  floor_s="$(date -u -d "$floor" +%s 2>/dev/null)" || { do_log "FATAL CHANNEL_RULE_CHECK_NOT_BEFORE is not a date: $floor"; return 1; }
  m="$(cr_map)"
  fault="$(cr_map_fault)"
  if [[ -n "$fault" ]]; then do_log "ALARM the channel rules map $m is $fault: every channel reads as held from automatic posts"; return 2; fi
  spl_cr_rows "$m" || return 2
  mt="$(stat -c %Y "$m")" || return 2
  if (( mt < floor_s )); then do_log "WARN $m is older than $floor: a map restored from before the holds"; rc=3; fi
  if (( SPL_CR_HOLDS == 0 )); then do_log "WARN $m holds nothing: no row has no-auto-post, every channel is free"; rc=3; fi
  IFS=, read -r -a want <<<"${CHANNEL_RULE_CHECK_WANT:-}"
  for w in "${want[@]}"; do
    read -r t c <<<"$w"
    cr_no_auto_post "$t" "$c" 2>/dev/null || { do_log "WARN $m does not hold $t #$c"; rc=3; }
  done
  (( rc == 0 )) && do_log "OK $m: $SPL_CR_ROWS row(s), $SPL_CR_HOLDS hold(s)"
  return "$rc"
}

# spl_cr_columns: the row of the env, as SPL_CR_COL.
spl_cr_columns() {
  local t="${CHANNEL_RULE_TENANT:-}" c="${CHANNEL_RULE_CHANNEL:-}" hold=-
  if [[ "$c" == '*' ]]; then SPL_CR_COL=("$t" '*' - - - - no-auto-post); return; fi
  [[ "${CHANNEL_RULE_NO_AUTO_POST:-}" == 1 ]] && hold=no-auto-post
  SPL_CR_COL=("$t" "$c" "${CHANNEL_RULE_DOC:-}" "${CHANNEL_RULE_ENV:-}" "${CHANNEL_RULE_AGENT:-}" "${CHANNEL_RULE_SOLE:--}" "$hold")
}

spl_cr_set() {
  local dry=1 drc m fault why row old src tmp t c
  local -a SPL_CR_COL=()
  if spl_dry_run; then :; else drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_cr_columns
  why="$(spl_cr_row_why "${SPL_CR_COL[@]}")"
  if [[ -n "$why" ]]; then do_log "FATAL CHANNEL_RULE_*: the row $why"; return 1; fi
  t="${SPL_CR_COL[0]}" c="${SPL_CR_COL[1]}"
  row="$(IFS=$'\t'; printf '%s' "${SPL_CR_COL[*]}")"
  m="$(cr_map)"
  fault="$(cr_map_fault)"
  src="$m"
  if [[ "$fault" == missing && "${CHANNEL_RULE_CREATE:-}" == 1 ]]; then src=/dev/null
  elif [[ -n "$fault" ]]; then do_log "FATAL the map $m is $fault; CHANNEL_RULE_CREATE=1 starts a new one only when it is missing"; return 2; fi
  old="$(awk -F'\t' -v t="$t" -v c="$c" '$1 == t && $2 == c' "$src")"
  if [[ "$old" == "$row" ]]; then do_log "OK $t #$c already has this row in $m"; return 0; fi
  if [[ -n "$old" && "${CHANNEL_RULE_REPLACE:-}" != 1 ]]; then do_log "FATAL $t #$c has another row in $m; CHANNEL_RULE_REPLACE=1 replaces it"; return 3; fi
  if ((dry)); then do_log "PLAN $m gets: $row"; return 0; fi
  tmp="$(mktemp "$m.XXXXXX")" || { do_log "FATAL cannot write next to $m"; return 1; }
  if [[ "$src" == "$m" ]]; then cp -p "$m" "$tmp"; else chmod 0664 "$tmp"; fi &&
    awk -F'\t' -v t="$t" -v c="$c" -v r="$row" '$1 == t && $2 == c { if (!d++) print r; next } { print } END { if (!d) print r }' "$src" >"$tmp" &&
    mv -f "$tmp" "$m" || { rm -f "$tmp"; do_log "FATAL cannot replace $m"; return 1; }
  do_log "OK $m: $t #$c written"
}

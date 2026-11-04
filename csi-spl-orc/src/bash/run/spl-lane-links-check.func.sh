#!/bin/bash
#------------------------------------------------------------------------------
# @description Every 15 min: the live lane rows of the fleet lane map that lack
# @description a discussion (topic) or an issue, named one per line and, with
# @description DELIVER=1, sent by spool to the dispatch lease holder (spec 153
# @description 3.20, SPL-4797; owner HUM-10, t1 0c2d08a2 msg 08ac07da: "the
# @description links must be enforced , by even some kind of dispatcher , cron
# @description scheduled work to check them"). It fills nothing and searches
# @description nothing (msg 937e89a4): the holder asks the lane. A role seat
# @description (001-003, or a row the role rotation wrote) is no lane and is
# @description left out; `unknown` (the value old rows got, spec 153 3.20) is
# @description a value, not a gap; a row not written for LINKS_CHECK_MAX_AGE_H
# @description is a dead lane, not looked at. The same list is sent again only
# @description after LINKS_CHECK_RESEND_MIN; while another machine holds the
# @description lease this one logs and sends nothing. Exit 0 none missing or
# @description sent, 3 lanes are missing links (DELIVER unset), 1 a failure,
# @description 2 the hub did not answer. Run by unanswered-sweep-cron.sh.
# @param DELIVER (optional) - 1 sends the list to the lease holder; default 0, print only
# @param LINKS_CHECK_TO (optional) - the recipient; default the dispatch lease holder (<ID>@<box>)
# @param LINKS_CHECK_FROM (optional) - the sender; default LEASE_ORCH, else role seat 1
# @param LINKS_CHECK_MAX_AGE_H (optional) - a row older than this many hours is not looked at, default 24
# @param LINKS_CHECK_RESEND_MIN (optional) - minutes before an unchanged list is sent again, default 120
# @param LINKS_CHECK_SEND (optional, tests) - replaces spool-send.sh
# @param LANE_FLEET LANE_HUB_CMD (optional) - as do_spl_lane_map
# @example ./run -a do_spl_lane_links_check
# @example ENV=prd DELIVER=1 ./run -a do_spl_lane_links_check
#------------------------------------------------------------------------------

declare -F spl_lane_init >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-map.func.sh"
declare -F spl_lease_read >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-dispatch-lease.func.sh"

do_spl_lane_links_check() {
  local deliver="${DELIVER:-0}" age_h="${LINKS_CHECK_MAX_AGE_H:-24}" rows list n
  [[ "$deliver" =~ ^[01]$ ]] || { do_log "FATAL DELIVER must be 0 or 1, got '$deliver'"; return 1; }
  [[ "$age_h" =~ ^[0-9]+$ ]] || { do_log "FATAL LINKS_CHECK_MAX_AGE_H must be a whole number of hours, got '$age_h'"; return 1; }
  declare -F spl_is_role_seat >/dev/null || source "$PROJ_PATH/src/bash/features/spawn-agents/lib/spool-env.inc.sh"
  spl_lane_init || return 1
  [[ "$LANE_MODE" == hub ]] || { do_log "FATAL no fleet (LANE_FLEET / LEASE_FLEET in lease.conf): no hub lane rows to check"; return 1; }
  rows="$(spl_lane_hub --fleet "$LANE_FLEET" 2>&1)" || { do_log "FATAL the hub lane map did not answer: $(tail -1 <<<"$rows")"; return 2; }
  list="$(spl_lane_links_missing "$rows" "$age_h")" || { do_log "FATAL the hub lane map answer is no lane list: $(head -c 200 <<<"$rows")"; return 1; }
  n="$(grep -c . <<<"$list")"
  if (( n == 0 )); then
    do_log "OK every live lane of fleet $LANE_FLEET names its discussion and its issue"
    return 0
  fi
  printf '%s\n' "$list"
  do_log "WARN $n live lane(s) of fleet $LANE_FLEET lack a discussion or an issue"
  (( deliver == 1 )) || return 3
  spl_lane_links_deliver "$list" "$n"
}

# spl_lane_links_missing ANSWER MAX_AGE_H -> one line per live lane row with
# no topic or no issue: `<ID>@<box> discussion=<topic|MISSING>
# issue=<key|MISSING> branch=<branch>`, sorted. Role seats, legacy ids and
# rows older than MAX_AGE_H are left out.
spl_lane_links_missing() {
  local id box topic issue branch scope
  jq -e '.lanes | type == "array"' <<<"$1" >/dev/null 2>&1 || return 1
  jq -r --argjson max "$(( $2 * 3600 ))" '.lanes[] | select(.state == "live" and ((.age_s // 0) <= $max))
    | select((.topic // "") == "" or (.issue_key // "") == "")
    | [.agent_id, .agent_box, (.topic // ""), (.issue_key // ""), (.branch // ""), (.scope // "")] | map(gsub("[\u001f\n]"; " ")) | join("\u001f")' <<<"$1" |
  while IFS=$'\x1f' read -r id box topic issue branch scope; do
    [[ "$id" =~ ^[acgmq]-[0-9]{3}$ ]] || continue
    spl_is_role_seat "$id" && continue
    [[ "$scope" =~ ^role\ [acgmoqu]-[0-9]{3}\ \(rotation\  ]] && continue
    printf '%s@%s discussion=%s issue=%s branch=%s\n' "$id" "$box" "${topic:-MISSING}" "${issue:-MISSING}" "${branch:--}"
  done | sort
}

# spl_lane_links_deliver LIST N: one spool note to the lease holder on task
# lane-links-check, unless the same LIST went out less than
# LINKS_CHECK_RESEND_MIN ago, or another machine holds the lease.
spl_lane_links_deliver() {
  local to last="${SPOOL_ROOT:-/var/spool-hub}/dispatch/lane-links-check.last" sum prev="" ts=0 now from body
  local send="${LINKS_CHECK_SEND:-$PROJ_PATH/src/bash/features/spawn-agents/scripts/spool-send.sh}"
  spl_lease_init ro && spl_lease_conf && spl_lease_read || return 1
  to="${LINKS_CHECK_TO:-}"
  if [[ -z "$to" ]]; then
    if spl_lease_remote 2>/dev/null; then do_log "INFO the lease holder $LH is on another machine: its own check sends"; return 0; fi
    [[ "$LH" != none ]] || { do_log "FATAL no dispatch lease holder to tell (LINKS_CHECK_TO names one)"; return 1; }
    to="$LH"
  fi
  sum="$(printf '%s\n' "$1" | sha256sum | cut -c1-16)"
  now="$(date +%s)"
  [[ -r "$last" ]] && read -r prev ts <"$last"
  [[ "$ts" =~ ^[0-9]+$ ]] || ts=0
  if [[ "$prev" == "$sum" ]] && (( now - ts < ${LINKS_CHECK_RESEND_MIN:-120} * 60 )); then
    do_log "INFO the same $2 lane(s) went to the holder $(( (now - ts) / 60 )) min ago: not sent again"
    return 0
  fi
  from="${LINKS_CHECK_FROM:-${LEASE_ORCH:-$(spl_role_seat 1)}}"
  body="**LANES WITHOUT LINKS: $2 live lane(s) lack a discussion or an issue** (spec 153 3.20, owner t1 f94e07bf msg 33f8eecb: each lane links its issue and the discussion it came from). Ask each lane for its discussion / issue and have it rewrite its row (\`lane-map.sh put --agent <ID> --topic <uuid> --issue <KEY>\`); no search, no auto-fill.

$(sed 's/^/- /' <<<"$1")"
  SPOOL_ROOT="${SPOOL_ROOT:-/var/spool-hub}" bash "$send" --from "$from" --to "$to" --kind note --task lane-links-check \
    --body "$body" >/dev/null 2>&1 8>&- 9>&- || { do_log "WARN could not send the lane links note to $to"; return 1; }
  printf '%s %s\n' "$sum" "$now" >"$last.tmp.$$" && mv -f "$last.tmp.$$" "$last"
  do_log "OK sent $2 lane(s) without links to $to (task lane-links-check)"
}

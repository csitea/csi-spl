#!/bin/bash
#------------------------------------------------------------------------------
# @description do_spl_issue_stale_sweep - end the wip issues whose lane is
# @description gone and was never ended (SPL-5935; night reflection 2026-11-18,
# @description SPL-5922: 84 lane and seat brief issues stayed wip with no lane;
# @description ruled by c-001, ask af0acaf9: the fleet may end them without the
# @description owner). It carries out the owner rule that an issue holds the
# @description true status and a lane that ends without landing ends its issue
# @description (LANE_ISSUE_OP=end). An issue is ended as diss, reason "lane gone,
# @description never ended (sweep)", ONLY when ALL of these hold:
# @description   1. created_by is an agent id, not HUM-*
# @description   2. kind issue, not epic or feature
# @description   3. status wip
# @description   4. the assignee is not HUM-*
# @description   5. not a discussion issue (the card LANE_ISSUE_OP=discussion files)
# @description   6. no live lane on any box names the key (do_spl_lane_map: issue_key,
# @description      origin_issue, scope, topic, branch, files, and its brief / seed here)
# @description   7. no commit message on origin/master names the key
# @description   8. no ask in state open, acked, queued, placing or needs_owner names it
# @description   9. its last update is STALE_IDLE_DAYS or more days ago
# @description Oldest first, at most STALE_MAX a run. A lane map read only on
# @description this machine (LOCAL-ONLY), or any list that cannot be read, stops
# @description the sweep: nothing written, one FATAL line says why.
# @description DRY_RUN=1 (default) prints the would-end list (key, last update,
# @description title, the conditions held) and the kept counts, and writes no
# @description issue (the readers keep their own housekeeping: the ask book's
# @description journal sync, the lane map's hub-down note, a git fetch).
# @description DRY_RUN=0 comments the reason on each, then sets diss
# @description (reversible: set wip again). Turning it on is the orchestrator's call.
# @param ENV (optional) - dev or prd; default the dispatch lease's LEASE_ENV, else prd
# @param TENANT_ID (optional) - default the lease's LEASE_TENANT
# @param DESK_AGENT (optional) - the desk agent that reads and writes; default the dispatch lease holder's id
# @param STALE_MAX (optional) - at most this many ends a run, 1..50 (the brief's ceiling), default 50
# @param STALE_IDLE_DAYS (optional) - 1..3650; default cnf env.rhythm.zombie_idle_days, else 7
# @param STALE_GIT_DIR (optional) - the repo whose origin/master is read, default this checkout
# @param STALE_GIT_FETCH (optional) - 1 (default) fetches origin master first, a failed fetch stops; 0 reads the ref as it is
# @param STALE_NOW (optional) - the moment judged, ISO-8601 (tests)
# @param SPOOL_ROOT (optional) - default /var/spool-hub
# @param DRY_RUN (optional) - 1 (default) or 0
# @example ./run -a do_spl_issue_stale_sweep
# @example STALE_MAX=10 DRY_RUN=0 ./run -a do_spl_issue_stale_sweep
#------------------------------------------------------------------------------
# Test seams: spl_issue_list_fetch, do_spl_lane_map, do_spl_asks_open,
# spl_stale_cited, spl_desk_issue_run and do_spl_desk_cnf are functions a
# test replaces.

do_spl_issue_stale_sweep() {
  local root="${SPOOL_ROOT:-/var/spool-hub}" dry=1 holder work rc=0
  if spl_dry_run; then :; else local drc=$?; [[ $drc -eq 1 ]] || return 1; dry=0; fi
  spl_stale_conf || return 1
  read -r holder _ <"$root/dispatch/lease" 2>/dev/null || holder=""
  export ENV="${ENV:-$(spl_stale_lease_conf "$root" LEASE_ENV prd)}"
  export TENANT_ID="${TENANT_ID:-$(spl_stale_lease_conf "$root" LEASE_TENANT "")}"
  export DESK_AGENT="${DESK_AGENT:-${holder%@*}}"
  [[ -n "$TENANT_ID" && -n "$DESK_AGENT" ]] ||
    { do_log "FATAL issue-stale-sweep: no TENANT_ID / DESK_AGENT (LEASE_TENANT in $root/dispatch/lease.conf, the dispatch holder): nothing written"; return 1; }
  do_spl_desk_cnf || return 1
  work="$(mktemp -d)" || return 1
  if spl_stale_read "$work" &&
    python3 "$PROJ_PATH/src/bash/scripts/issue-stale-sweep-judge.py" "$work" "$STALE_MAX" "$STALE_IDLE_DAYS" "$root" "${STALE_NOW:-}" >"$work/verdict.tsv"; then
    spl_stale_finish "$work/verdict.tsv" "$dry" || rc=1
  else
    do_log "FATAL issue-stale-sweep: stopped before any write (above)"; rc=1
  fi
  rm -rf "$work"
  return $rc
}

spl_stale_lease_conf() {
  local v
  v="$(sed -n "s/^$2=//p" "$1/dispatch/lease.conf" 2>/dev/null | tail -1)"
  echo "${v:-$3}"
}

# spl_stale_conf: STALE_MAX and STALE_IDLE_DAYS checked; the idle default is
# the zombie sweep's (cnf env.rhythm.zombie_idle_days, owner poll d102c775 Q1).
spl_stale_conf() {
  local oa="${SPL_ORG_APP:-$(basename "${PROJ_PATH:-csi-spl-orc}")}" cnf v
  oa="${oa%-orc}"; cnf="${RHYTHM_CNF:-${APP_PATH:-.}/$oa-cnf/$oa/all.env.yaml}"
  if [[ -z "${STALE_IDLE_DAYS:-}" && -r "$cnf" ]] && command -v yq >/dev/null 2>&1; then
    v="$(yq -r '.env.rhythm.zombie_idle_days // ""' "$cnf" 2>/dev/null)"; STALE_IDLE_DAYS="$v"
  fi
  STALE_MAX="${STALE_MAX:-50}" STALE_IDLE_DAYS="${STALE_IDLE_DAYS:-7}"
  [[ "$STALE_MAX" =~ ^[1-9][0-9]?$ ]] && ((STALE_MAX <= 50)) ||
    { do_log "FATAL STALE_MAX must be 1..50, got: '$STALE_MAX'"; return 1; }
  [[ "$STALE_IDLE_DAYS" =~ ^[1-9][0-9]{0,3}$ ]] && ((STALE_IDLE_DAYS <= 3650)) ||
    { do_log "FATAL STALE_IDLE_DAYS must be 1..3650, got: '$STALE_IDLE_DAYS'"; return 1; }
  [[ "${STALE_GIT_FETCH:-1}" =~ ^[01]$ ]] || { do_log "FATAL STALE_GIT_FETCH must be 0 or 1, got: '$STALE_GIT_FETCH'"; return 1; }
}

# spl_stale_read <work>: issues.json, lanes.json, asks.json and cited.txt;
# rc 1 and a FATAL line when one cannot be read, or the lane map read only here.
spl_stale_read() {
  local w="$1" out
  spl_issue_list_fetch --status wip --limit 100 >"$w/issues.json" 2>/dev/null &&
    jq -e '(.result // .) | .issues | type == "array"' "$w/issues.json" >/dev/null 2>&1 ||
    { do_log "FATAL issue-stale-sweep: the wip issues were not read (spl_issue_list_fetch)"; return 1; }
  out="$(LANE_FORMAT=json RUN_STDOUT_IS_DATA=1 do_spl_lane_map 2>/dev/null | grep '^{' | tail -1)"
  jq -e '(.lanes | type == "array") and .hub == "ok"' <<<"$out" >/dev/null 2>&1 ||
    { do_log "FATAL issue-stale-sweep: the fleet lane map was not read from every box (do_spl_lane_map hub=$(jq -r '.hub // "none"' <<<"$out" 2>/dev/null || echo unreadable); LOCAL-ONLY is not read)"; return 1; }
  printf '%s\n' "$out" >"$w/lanes.json"
  out="$(ASKS_ALL=1 ASKS_FORMAT=json RUN_STDOUT_IS_DATA=1 do_spl_asks_open 2>/dev/null | grep '^{' | tail -1)"
  jq -e '(.asks | type == "array") and (.hub == "ok" or .hub == "partial")' <<<"$out" >/dev/null 2>&1 ||
    { do_log "FATAL issue-stale-sweep: the ask book was not read from the hub (do_spl_asks_open)"; return 1; }
  printf '%s\n' "$out" >"$w/asks.json"
  spl_stale_cited >"$w/cited.txt" || { do_log "FATAL issue-stale-sweep: origin/master's commit messages were not read"; return 1; }
}

# spl_stale_cited: every issue key a commit message on origin/master names,
# one a line, after a fetch (STALE_GIT_FETCH=0 skips it).
spl_stale_cited() {
  local dir="${STALE_GIT_DIR:-$PROJ_PATH}"
  if [[ "${STALE_GIT_FETCH:-1}" == 1 ]]; then
    git -C "$dir" fetch -q origin master >&2 || { do_log "FATAL git fetch origin master failed in $dir (STALE_GIT_FETCH=0 reads the ref as it is)" >&2; return 1; }
  fi
  git -C "$dir" rev-parse --verify -q 'origin/master^{commit}' >/dev/null || return 1
  git -C "$dir" log origin/master --format=%B | grep -oE '\b[A-Z][A-Z0-9]{0,9}-[1-9][0-9]*\b' | sort -u
  return 0
}

# spl_stale_finish <verdict.tsv> <dry>: the kept counts, the would-end list,
# and with dry 0 the ends.
spl_stale_finish() {
  local v="$1" dry="$2" n key up title held ok=0 bad=0 kept
  n="$(grep -c '^end' "$v")"
  kept="$(awk -F'\t' '$1 == "keep" { k[$3]++ } END { for (c in k) printf "%s %d, ", c, k[c] }' "$v" | sed 's/, $//')"
  echo "issue-stale-sweep: $(grep -c . "$v") wip issue(s), kept by the first failed condition: ${kept:-none}"
  while IFS=$'\t' read -r _ key up title held; do
    if ((dry)); then echo "issue-stale-sweep: WOULD END $key (last update $up) $title :: $held"; continue; fi
    if spl_stale_end_one "$key" "$held"; then ok=$((ok + 1)); echo "issue-stale-sweep: ended $key (last update $up) $title"
    else bad=$((bad + 1)); fi
  done < <(grep '^end' "$v")
  if ((dry)); then
    echo "OK issue-stale-sweep DRY_RUN=1 (cap $STALE_MAX, idle $STALE_IDLE_DAYS d): would end $n; nothing written"
    return 0
  fi
  echo "OK issue-stale-sweep DRY_RUN=0 (cap $STALE_MAX, idle $STALE_IDLE_DAYS d): ended $ok, failed $bad"
  ((bad == 0))
}

# spl_stale_end_one <key> <held>: the reason comment, then diss (the comment
# first: an epic's last close archives its issues, SPL-3064).
spl_stale_end_one() {
  local out
  out="$(spl_desk_issue_run comment --ref "$1" \
    --body "Ended as diss by do_spl_issue_stale_sweep: lane gone, never ended (sweep). $2. Reversible: set the status back to wip." 2>&1)" ||
    { do_log "WARN issue-stale-sweep: comment on $1 failed, left wip: $(tail -1 <<<"$out")"; return 1; }
  out="$(spl_desk_issue_run update --ref "$1" --status diss 2>&1)" ||
    { do_log "WARN issue-stale-sweep: diss of $1 failed: $(tail -1 <<<"$out")"; return 1; }
}

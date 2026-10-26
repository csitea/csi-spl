#!/bin/bash
# @description The fleet-wide lane map: who owns what, on EVERY machine of the
# @description fleet (CLE-77920, specs/058 G4 / N2). `git worktree list` sees one
# @description machine's lanes only, so a scope check on the home box was blind
# @description to the satellite. The spawn path writes one row per agent on the
# @description hub (`spool lane`, rdb 0096: <id>@<box>, repo, branch, scope,
# @description files, topic, state), exit-clean sets it done
# @description (do_spl_lane_put), and this action reads them all, joined with
# @description this machine's own worktrees so a lane spawned before the map
# @description existed (or while the hub was down) still shows (src local).
# @description Without a fleet (no LANE_FLEET / lease.conf LEASE_FLEET) the map
# @description is the local worktrees only - the one-machine behaviour.
# @description With LANE_CHECK it is the spawn path's collision check: exit 3
# @description when a LIVE lane of another agent owns an overlapping path. The
# @description table form then prints ONLY the verdict: `free`, or one line per
# @description overlap `<path> owned by <ID>@<box> <branch>` (token practice 01).
# @description A free path is exit 4 instead of 0 when another build lane with
# @description a live pane has `files: []`: its scope is unknown, so one line per
# @description such lane `unknown: <ID>@<box> <branch> has no files recorded; ask
# @description it or read its brief` replaces `free`.
# @description The hub read is tried up to 3 times inside 10 s (SPL-2180). A hub
# @description that still does not answer leaves the local map, marked: the
# @description table and the check open with `LOCAL-ONLY: the hub did not
# @description answer ...`, the check says exit 5 where it would have said
# @description `free` (other machines unread: not free), json says
# @description `hub: unreachable`, and one #alerts note is raised per box per
# @description 15 min (spl_lane_hub_down_alert).
# @description The default table hides the rows 2 h old or older, and those with
# @description no age while the hub answered, behind a footer
# @description `N older rows hidden (--all)`; LANE_ALL=1 shows every row.
# @param LANE_FLEET (optional) - the fleet; default LEASE_FLEET (env, then <spool root>/dispatch/lease.conf)
# @param LANE_ENV / LANE_TENANT (optional) - the hub env (dev|prd|self) and the tenant holding the map; default LEASE_ENV / LEASE_TENANT
# @param LANE_DESK_BOX (optional) - the pinned desk box whose key signs the calls; default LEASE_DESK_BOX, then spl_desk_box_default
# @param LANE_FORMAT (optional) - table (default) or json
# @param LANE_ALL (optional) - 1 also lists done rows (the hub keeps them a week) and the older rows the table hides
# @param LANE_CHECK (optional) - comma-separated paths the caller is about to own; exit 3 on an overlap with another live lane, exit 4 when none overlaps but a live build lane has no files recorded
# @param LANE_AGENT (optional) - the caller's own id, skipped by LANE_CHECK
# @param LANE_REPO_DIRS (optional) - space-separated repos whose local worktrees join the map; default the repo holding this tree
# @param LANE_HUB_CMD (optional, tests) - replaces the hub call: gets `lane <args>`, prints the hub's answer
# @param LANE_HUB_TRIES / LANE_HUB_BACKOFF / LANE_HUB_BUDGET (optional) - the hub read: tries (default 3), seconds between them (default "1 2"), total seconds (default 10)
# @param LANE_ALERT_GAP_S (optional) - at most one hub-down #alerts note per box in this many seconds, default 900
# @param LANE_ALERT_DIR (optional) - where the alert's per-box stamp lives, default <spool root>/dispatch
# @param LANE_ALERT_AGENT (optional) - the alert's author, default lease.conf LEASE_ORCH
# @param LANE_ALERT_CMD (optional, tests) - replaces the #alerts post: gets the text on stdin
# @param LANE_BOX_ROW_S (optional) - rewrite this box's BOX-0 load row when it is this old, default 300 s
# @param LANE_BOX_ROW_MAX_S (optional) - a box's BOX-0 row older than this is not read, default 3600 s
# @param LANE_PANES_CMD (optional, tests) - replaces the tmux read: prints `<pane_dead> <window name>` lines
# @example ./run -a do_spl_lane_map
# @example LANE_CHECK=csi-spl-orc/src/bash/run/,csi-spl-doc/specs/058-multi-machine-fleet/ LANE_AGENT=CLE-77920 ./run -a do_spl_lane_map
# @example LANE_FORMAT=json LANE_ALL=1 ./run -a do_spl_lane_map

declare -F spl_desk_box_default >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-box.func.sh"
declare -F spl_box_ci_jobs >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-box-ci.func.sh"

do_spl_lane_map() {
  local rows hub_json="" fmt="${LANE_FORMAT:-table}" rc=0 live_here load
  [[ "$fmt" =~ ^(table|json)$ ]] || { do_log "FATAL LANE_FORMAT must be table or json"; return 1; }
  spl_lane_init || return 1
  if [[ "$LANE_MODE" == hub ]]; then
    if spl_lane_hub_read; then
      LANE_HUB_STATE=ok hub_json="$LANE_HUB_JSON"
      (( LANE_HUB_TRY > 1 )) && do_log "INFO the hub answered on try $LANE_HUB_TRY"
    else
      LANE_HUB_STATE=unreachable hub_json=""
      do_log "WARN the hub did not answer ($LANE_HUB_TRIED tries): this map shows only this machine's lanes (local worktrees)"
      spl_lane_hub_down_alert
    fi
  fi
  rows="$(spl_lane_merge "${hub_json:-{\"lanes\":[]\}}" "$(spl_lane_local_rows)")" || { do_log "FATAL cannot merge the lane rows"; return 1; }
  live_here="$(spl_lane_live_here)"
  load="$(spl_lane_load "$rows" "$live_here" "$(spl_lane_clis_here)")"
  spl_lane_box_report "$rows" "$live_here" "$load"
  # the box rows feed the load only: they are no lane
  rows="$(jq -c --arg b "$LANE_BOX_ROW_ID" '[.[] | select(.agent_id != $b)]' <<<"$rows")"
  [[ "${LANE_ALL:-0}" == 1 ]] || rows="$(jq -c '[.[] | select(.state == "live")]' <<<"$rows")"

  if [[ "$fmt" == json ]]; then
    jq -c --arg f "${LANE_FLEET:-}" --arg h "$LANE_HUB_STATE" --argjson t "${LANE_HUB_TRIED:-0}" --argjson load "$load" \
      '{fleet: $f, hub: $h, hub_tries: $t, load: $load, lanes: .}' <<<"$rows"
  elif [[ -z "${LANE_CHECK:-}" ]]; then
    [[ "$LANE_HUB_STATE" == unreachable ]] && spl_lane_local_only_line
    spl_lane_load_header "$load"
    spl_lane_table_recent "$rows"
  fi
  if [[ -n "${LANE_CHECK:-}" ]]; then
    spl_lane_check "$rows" "$load" || rc=$?
  fi
  return "$rc"
}

# LANE_MODE hub|local, LANE_HUB_STATE ok|unreachable|off, and the hub call's
# settings. Never fails for a missing fleet: that is the one-machine case.
spl_lane_init() {
  spl_lane_conf
  LANE_FLEET="${LANE_FLEET:-${LEASE_FLEET:-}}"
  LANE_ENV="${LANE_ENV:-${LEASE_ENV:-}}"
  LANE_TENANT="${LANE_TENANT:-${LEASE_TENANT:-}}"
  LANE_DESK_BOX="${LANE_DESK_BOX:-${LEASE_DESK_BOX:-$(spl_desk_box_default)}}"
  LANE_BOX="${LANE_BOX:-$(spl_desk_box_default)}"
  LANE_MODE=local LANE_HUB_STATE=off
  [[ -n "$LANE_FLEET" ]] || return 0
  local k
  for k in LANE_FLEET LANE_BOX; do
    [[ "${!k}" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL $k must be a lowercase slug ([a-z0-9-], up to 32), got '${!k}'"; return 1; }
  done
  LANE_MODE=hub
  [[ -n "${LANE_HUB_CMD:-}" ]] && return 0
  [[ "$LANE_TENANT" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL LANE_TENANT is not set (env, or LEASE_TENANT in lease.conf)"; return 1; }
  [[ "$LANE_ENV" =~ ^(dev|prd|self)$ ]] || { do_log "FATAL LANE_ENV must be dev, prd or self (env, or LEASE_ENV in lease.conf)"; return 1; }
  ENV="$LANE_ENV" do_spl_desk_cnf || return 1
  spl_host_spool || return 1
  LANE_DESK_DIR="$SPL_STATE_DIR/desk/$LANE_TENANT/$LANE_DESK_BOX"
  [[ -s "$LANE_DESK_DIR/pinned" ]] ||
    { do_log "FATAL $LANE_DESK_BOX is not pinned in $LANE_TENANT ($LANE_DESK_DIR): seat a desk there first (do_spl_desk_up)"; return 1; }
}

# The fleet settings from the dispatch lease.conf (CLE-77911) for the keys
# not already in the environment. Read, never sourced: every agent may write
# that dir.
spl_lane_conf() {
  local f="${SPOOL_ROOT:-/var/spool-hub}/dispatch/lease.conf" k v
  [[ -f "$f" ]] || return 0
  while IFS='=' read -r k v; do
    [[ -z "${!k:-}" ]] && printf -v "$k" '%s' "$v"
  done < <(grep -E '^LEASE_(FLEET|ENV|TENANT|DESK_BOX|ORCH)=[a-z0-9][a-z0-9-]*$' "$f")
  return 0
}

# The hub's rows into LANE_HUB_JSON, tried LANE_HUB_TRIES times (default 3)
# with LANE_HUB_BACKOFF seconds between them (default "1 2", the last value
# repeats) inside LANE_HUB_BUDGET seconds (default 10): one dropped call no
# longer turns the fleet map into this machine's (SPL-2180). A try's timeout
# is its share of the budget: (budget - the backoff waits) / tries, at least
# 1 s, at most LANE_TIMEOUT and what is left, so a HUNG try leaves room for
# the next ones (SPL-3503: the whole budget on try 1 was "1 tries").
# LANE_HUB_TRY: the try that answered (0: none); LANE_HUB_TRIED: the tries made.
spl_lane_hub_read() {
  local tries="${LANE_HUB_TRIES:-3}" budget="${LANE_HUB_BUDGET:-10}" max="${LANE_TIMEOUT:-30}" start=$SECONDS left n out wait
  local share waits=0 w
  local -a back
  read -r -a back <<<"${LANE_HUB_BACKOFF:-1 2}"
  [[ "$tries" =~ ^[1-9][0-9]*$ ]] || tries=3
  [[ "$budget" =~ ^[1-9][0-9]*$ ]] || budget=10
  [[ "$max" =~ ^[1-9][0-9]*$ ]] || max=30
  for (( n = 1; n < tries; n++ )); do
    w="${back[n - 1]:-${back[${#back[@]} - 1]:-1}}"
    [[ "$w" =~ ^[0-9]+$ ]] || w=1
    waits=$(( waits + w ))
  done
  share=$(( (budget - waits) / tries ))
  (( share >= 1 )) || share=1
  (( share <= max )) || share=$max
  LANE_HUB_JSON="" LANE_HUB_TRY=0 LANE_HUB_TRIED=0
  for (( n = 1; n <= tries; n++ )); do
    left=$(( budget - (SECONDS - start) ))
    (( left > 0 )) || break
    LANE_HUB_TRIED=$n
    if out="$(LANE_TIMEOUT=$(( left < share ? left : share )) spl_lane_hub --fleet "$LANE_FLEET" 2>"${LANE_ERR:-/dev/null}")" &&
      jq -e '.lanes | type == "array"' >/dev/null 2>&1 <<<"$out"; then
      LANE_HUB_JSON="$out" LANE_HUB_TRY=$n
      return 0
    fi
    (( n < tries )) || break
    wait="${back[n - 1]:-${back[${#back[@]} - 1]:-1}}"
    [[ "$wait" =~ ^[0-9]+$ ]] || wait=1
    (( wait < budget - (SECONDS - start) )) || break
    sleep "$wait"
  done
  return 1
}

# The marker of a one-box map: the first line of the table, and of the
# check's verdict. A caller must never read "free" or "every lane" from it.
spl_lane_local_only_line() {
  echo "LOCAL-ONLY: the hub did not answer after $LANE_HUB_TRIED tries; this map is $LANE_BOX's own lanes, not the fleet's"
}

# ONE #alerts note per box per LANE_ALERT_GAP_S (default 900 s) while the map
# falls back to this machine's lanes, on the path the lease and the asks tick
# use (do_spl_desk_post, kind note, never a blocker), authored by the orch
# seat (lease.conf LEASE_ORCH; LANE_ALERT_AGENT overrides). The stamp
# <LANE_ALERT_DIR, default <spool root>/dispatch>/lane-map.hub-down.<box>
# holds the epoch of the last one; a stamp that cannot be written posts
# nothing (no rate limit, no alert). The post runs in the background: the hub
# just failed, and the map must not wait on it. LANE_ALERT_CMD (tests)
# replaces it, in this shell, with the text on stdin.
spl_lane_hub_down_alert() {
  local dir="${LANE_ALERT_DIR:-${SPOOL_ROOT:-/var/spool-hub}/dispatch}" gap="${LANE_ALERT_GAP_S:-900}" f last=0 now text who
  f="$dir/lane-map.hub-down.$LANE_BOX"
  now="$(date +%s)"
  [[ -r "$f" ]] && read -r last <"$f"
  [[ "$last" =~ ^[0-9]+$ ]] || last=0
  if (( now - last < gap )); then
    do_log "INFO the hub-down alert of $LANE_BOX was raised $(( now - last )) s ago: no second one inside ${gap} s"
    return 0
  fi
  if ! { mkdir -p "$dir" && echo "$now" >"$f.tmp.$$" && mv -f "$f.tmp.$$" "$f"; } 2>/dev/null; then
    rm -f "$f.tmp.$$" 2>/dev/null
    do_log "WARN cannot write $f: the hub-down alert is not raised"
    return 0
  fi
  text="**ALERT** lane map on $LANE_BOX: the hub did not answer $LANE_HUB_TRIED tries in a row (fleet $LANE_FLEET), so the lane map and \`lane-map.sh --check\` there see that machine only and say LOCAL-ONLY (exit 5, not free). Do: check the hub (\`./run -a do_check_hub_deploy\`) and the desk of $LANE_BOX. At most one such alert per box per $(( gap / 60 )) min."
  who="${LANE_ALERT_AGENT:-${LEASE_ORCH:-}}"
  if [[ -n "${LANE_ALERT_CMD:-}" ]]; then
    # shellcheck disable=SC2086 # a command line, split on purpose
    $LANE_ALERT_CMD <<<"$text" >/dev/null 2>&1 || do_log "WARN the hub-down alert command failed"
  elif [[ -n "${LANE_HUB_CMD:-}" || -z "$who" ]]; then
    do_log "ALERT (not posted: ${who:-no LEASE_ORCH}, ${LANE_HUB_CMD:+stub hub}): $text"
    return 0
  else
    ( ENV="$LANE_ENV" TENANT_ID="$LANE_TENANT" DESK_BOX="$LANE_DESK_BOX" DESK_AGENT="$who" DESK_CHANNEL=alerts \
        DESK_KIND=note DESK_BODY="$text" DRY_RUN=0 timeout "${LANE_ALERT_TIMEOUT:-120}" "${PROJ_PATH:-.}/run" -a do_spl_desk_post \
        </dev/null >>"$dir/lane-map.hub-down.out" 2>&1 7>&- 8>&- & ) 2>/dev/null
  fi
  do_log "ALERT the hub-down alert of $LANE_BOX is raised; the next one ${gap} s from now at the earliest"
}

# `spool lane <args>` as this machine's desk box, under a timeout.
spl_lane_hub() { spl_lane_spool lane "$@"; }

# `spool <verb> <args>` as this machine's desk box, under a timeout.
spl_lane_spool() {
  if [[ -n "${LANE_HUB_CMD:-}" ]]; then "$LANE_HUB_CMD" "$@"; return; fi
  SPOOL_ROOT="$LANE_DESK_DIR/spool" SPOOL_KEYS_DIR="$LANE_DESK_DIR/keys" SPOOL_BOX_ID="$LANE_DESK_BOX" \
    SPOOL_HUB_URL="$SPL_HUB_URL" SPOOL_TENANT="$LANE_TENANT" timeout "${LANE_TIMEOUT:-30}" "$SPL_SPOOL" "$@"
}

# The main checkouts of the repos in LANE_REPO_DIRS (default the repo holding
# this tree), one per line.
spl_lane_repo_tops() {
  local dirs="${LANE_REPO_DIRS:-}" d top
  if [[ -z "$dirs" ]]; then
    dirs="$(git -C "${PROJ_PATH:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    dirs="${dirs%/.git}"
  fi
  for d in $dirs; do
    top="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || continue
    printf '%s\n' "${top%/.git}"
  done
}

# This machine's lanes as rows: every worktree at <repo>-wt/<ID> of the repos
# in LANE_REPO_DIRS. A JSON array.
spl_lane_local_rows() {
  local top wt br
  for top in $(spl_lane_repo_tops); do
    wt="" br=""
    while IFS= read -r line; do
      case "$line" in
        "worktree "*) wt="${line#worktree }" br="" ;;
        "branch "*) br="${line#branch refs/heads/}" ;;
        "") spl_lane_local_row "$top" "$wt" "$br"; wt="" ;;
      esac
    done < <(git -C "$top" worktree list --porcelain 2>/dev/null; echo)
  done | jq -s -c '.'
}

spl_lane_local_row() {
  local top="$1" wt="$2" br="$3" id
  [[ -n "$wt" && "$(dirname "$wt")" == "${top}-wt" ]] || return 0
  id="$(basename "$wt")"
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  [[ "$id" =~ ^${SPOOL_PARTICIPANT_RX}$ ]] || return 0
  jq -n -c --arg a "$id" --arg b "$LANE_BOX" --arg r "$(basename "$top")" --arg br "$br" \
    '{agent_id: $a, agent_box: $b, repo: $r, branch: $br, scope: "", files: [], topic: "", state: "live", age_s: -1, src: "local"}'
}

# Hub rows win for an agent the hub knows; a local worktree the hub has no
# row for (or a live one when the hub says done) is kept, marked src local.
# Both values are files, not --argjson. One argument longer than
# MAX_ARG_STRLEN (32 pages; 131072 bytes when the page is 4096) makes the
# kernel refuse the exec ("Argument list too long") and the map dies before
# it prints. The fleet's hub answer crossed that line; either input can.
spl_lane_merge() {
  local hubf locf rc=1
  hubf="$(mktemp)" || return 1
  locf="$(mktemp)" || { rm -f "$hubf"; return 1; }
  # slurpfile yields a one-element array of the JSON value in the file.
  if printf '%s\n' "$1" >"$hubf" && printf '%s\n' "$2" >"$locf" &&
    jq -c -n --slurpfile hub "$hubf" --slurpfile loc "$locf" '
      ($hub[0].lanes // [] | map(. + {src: "hub"})) as $h
      | ($h | map({key: .agent_id, value: .}) | from_entries) as $byid
      | $h + [ $loc[0][] | select(($byid[.agent_id] // null) == null) ]
      | ([$loc[0][] | .agent_id]) as $here
      | map(. as $r | if $r.src == "hub" and ($here | index($r.agent_id)) != null then .src = "hub+local" else . end)'; then
    rc=0
  fi
  rm -f "$hubf" "$locf"
  return "$rc"
}

spl_lane_table() {
  jq -r '
    def cut($n): if length > $n then .[0:$n-1] + "~" else . end;
    (["AGENT@BOX", "STATE", "AGE", "REPO", "BRANCH", "TOPIC", "FILES", "SCOPE", "SRC"] | @tsv),
    (.[] | [ .agent_id + "@" + .agent_box, .state,
             (if .age_s < 0 then "-" elif .age_s < 3600 then "\(.age_s / 60 | floor)m" else "\(.age_s / 3600 | floor)h" end),
             .repo, (.branch | cut(40)), (.topic | cut(12)), (.files | join(",") | cut(60)), (.scope | cut(60)), .src ] | @tsv)' <<<"$1" |
    column -t -s $'\t'
}

# The default table: rows younger than LANE_RECENT_S (2 h), plus the rows
# with no age when the hub did not answer (then they are the whole map), and
# a footer counting the rest. LANE_ALL=1 prints every row, as before.
# A live role seat stays too, on every box. The id is bare (c-001, c-002,
# c-003, the same three spool_spawn_is_seat tests); the box is agent_box.
# One select keeps the input order, so two boxes of one id both stay.
# Done rows never reach this filter.
spl_lane_table_recent() {
  local shown hidden
  if [[ "${LANE_ALL:-0}" == 1 ]]; then spl_lane_table "$1"; return; fi
  declare -F spl_is_role_seat >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  shown="$(jq -c --argjson max "${LANE_RECENT_S:-7200}" --arg h "$LANE_HUB_STATE" --arg seat "^${SPL_ROLE_SEAT_RX}$" \
    '[.[] | select(
        (.state == "live" and (.agent_id | test($seat)))
        or (.age_s >= 0 and .age_s < $max)
        or (.age_s < 0 and $h != "ok"))]' <<<"$1")"
  spl_lane_table "$shown"
  hidden=$(( $(jq length <<<"$1") - $(jq length <<<"$shown") ))
  (( hidden == 0 )) || echo "$hidden older rows hidden (--all)"
}

# The reserved id of a box's LOAD row in the lane map: one row per box,
# BOX-0@<box>, scope `mem_kb=<MemAvailable> [ci=<n>] [cli=<kind>,...] [wk=<kind>:<pct>,...] live=<id>,...`: the agents
# with a live tmux pane on that box and its free memory, as that box itself
# read them. The hub stores it like any lane (no field of its own, no hub
# change); this action writes it (spl_lane_box_report) and the map never
# shows it as a lane. A legacy-grammar id no agent can hold.
LANE_BOX_ROW_ID=BOX-0

# LANE_TM: the tmux command on the box user's socket, hopping to that user
# when this is someone else (the panes live there).
spl_lane_tm() {
  local user sock
  user="${SPOOL_BOX_USER:-$(stat -c %U "${SPOOL_ROOT:-/var/spool-hub}" 2>/dev/null)}"
  case "$user" in ''|root|UNKNOWN) user="$(id -un)" ;; esac
  sock="${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u "$user" 2>/dev/null || id -u)/default}"
  LANE_TM=(tmux -u -S "$sock")
  [[ "$(id -un)" == "$user" ]] || LANE_TM=(sudo -n -u "$user" tmux -u -S "$sock")
}

# The agent ids with a live pane on THIS box, as a JSON array, from the tmux
# window names (the id is their first token, as the 40-window ceiling counts
# them; spool_id_of_window); dead panes do not count. null when tmux cannot
# be read (no server): the load then falls back to the rows.
spl_lane_live_here() {
  local out dead name id
  if [[ -n "${LANE_PANES_CMD:-}" ]]; then
    out="$($LANE_PANES_CMD 2>/dev/null)" || { echo null; return 0; }
  else
    spl_lane_tm
    out="$(timeout 10 "${LANE_TM[@]}" list-panes -a -F '#{pane_dead} #{window_name}' 2>/dev/null)" || { echo null; return 0; }
  fi
  declare -F spool_id_of_window_var >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  while read -r dead name; do
    [[ "$dead" == 0 ]] || continue
    spool_id_of_window_var id "$name"
    [[ -n "$id" ]] && printf '%s\n' "$id"
  done <<<"$out" | sort -u | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# The vendor kinds this box can start (spool_vendor_clis: the agent user's
# `command -v` of each *_BIN), as a JSON array; null = could not measure.
spl_lane_clis_here() {
  local out
  declare -F spool_vendor_clis >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  out="$(spool_vendor_clis 2>/dev/null)" || { echo null; return 0; }
  jq -R -c 'split(",") | map(select(length > 0))' <<<"$out"
}

# The load per box, as a JSON array of
# {box, here, live, busy, busy_ids, seats, clean_ids, mem, mem_kb, clis, src}: the
# agents live on the box NOW, split into busy (build lanes, their ids in
# busy_ids) and seats; clean_ids, from another box's BOX-0 row, are its lanes
# with `files: []` and a clean worktree (spl_lane_clean_here) (001-003 and the ids lease.conf
# names: they run the fleet, they are not build load). src says where the
# live agents come from:
#   panes  this box: its tmux panes (spl_lane_live_here)
#   box    another box: its BOX-0 row younger than LANE_BOX_ROW_MAX_S, plus
#          its lanes written live after that row, minus those written done
#   rows   no such row (an older box, tmux unreadable here): the live rows of
#          the last LANE_RECENT_S (2 h; rows with no age only while the hub is
#          down), the measure before the box rows
# live = the box is up: a pane or BOX-0 source, or any such row. mem =
# MemAvailable (here /proc/meminfo, LANE_MEMINFO in the tests; another box its
# BOX-0 row), "?" unknown. clis = the vendor kinds the box can start (SPL-1649:
# here CLIS_HERE, another box the cli= of its BOX-0 row), null unknown (an older
# box, rows only): spawn-window.sh places a lane only where its kind is. The boxes: this one first, then the lease.conf
# rankings (LEASE_PRIORITY*), then any other box a row names.
# spawn-window.sh places a lane by it; the table prints it as its header.
spl_lane_load() {  # ROWS (every merged row, done and BOX-0 too) LIVE_HERE (JSON array or null) [CLIS_HERE (JSON array or null)]
  declare -F spl_is_role_seat >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  local f="${SPOOL_ROOT:-/var/spool-hub}/dispatch/lease.conf" conf_boxes="" seat_ids="" kb
  if [[ -r "$f" ]]; then
    conf_boxes="$(sed -n 's/^LEASE_PRIORITY[A-Z_]*=\([a-z0-9,-]*\)$/\1/p' "$f" | tr ',' '\n' | grep -E '^[a-z0-9][a-z0-9-]{0,31}$')"
    seat_ids="$(sed -n 's/^LEASE_\(MASTER\|FAILOVER\|ORCH\)=\([A-Za-z0-9-]*\)$/\2/p' "$f")"
  fi
  kb="$(awk '$1 == "MemAvailable:" {print $2; exit}' "${LANE_MEMINFO:-/proc/meminfo}" 2>/dev/null)"
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=null
  jq -c --arg here "$LANE_BOX" --argjson herekb "$kb" --argjson herelive "${2:-null}" --argjson hereclis "${3:-null}" --arg h "$LANE_HUB_STATE" \
    --argjson max "${LANE_RECENT_S:-7200}" --argjson boxmax "${LANE_BOX_ROW_MAX_S:-3600}" --arg brid "$LANE_BOX_ROW_ID" \
    --arg conf "$conf_boxes" --arg seats "$seat_ids" --arg seatrx "^${SPL_ROLE_SEAT_RX}$" '
    ($seats | split("\n") | map(select(length > 0))) as $ids
    | def seat: test($seatrx) or (. as $a | $ids | index($a) != null);
      def gb: if . == null then "?" else (. / 104857.6 | round) as $t | "\($t / 10 | floor).\($t % 10)G" end;
      def field($k): [capture($k + "=(?<v>[^ ]*)")][0].v // "";
    [.[] | select(.agent_id == $brid and .state == "live" and .age_s >= 0 and .age_s < $boxmax)] as $reports
    | [.[] | select(.agent_id != $brid)] as $lanes
    | [$lanes[] | select(.state == "live" and ((.age_s >= 0 and .age_s < $max) or (.age_s < 0 and $h != "ok")))] as $recent
    | ([$here] + ($conf | split("\n")) + [$recent[].agent_box] + [$reports[].agent_box] | map(select(length > 0))) as $all
    | reduce $all[] as $b ([]; if index($b) then . else . + [$b] end)
    | map(. as $b
        | ([$reports[] | select(.agent_box == $b)] | sort_by(.age_s) | first) as $rep
        | (if $b == $here and $herelive != null then {src: "panes", ids: $herelive, kb: $herekb, clis: $hereclis}
           elif $rep != null then
             [$lanes[] | select(.agent_box == $b and .age_s >= 0 and .age_s < $rep.age_s)] as $since
             | {src: "box",
                ids: (($rep.scope | field("live") | split(",") | map(select(length > 0)))
                      + [$since[] | select(.state == "live") | .agent_id]
                      - [$since[] | select(.state == "done") | .agent_id]),
                clean: (($rep.scope | field("clean") | split(",") | map(select(length > 0)))
                        - [$since[] | .agent_id]),
                kb: ($rep.scope | field("mem_kb") | if test("^[0-9]+$") then tonumber else null end),
                clis: ([$rep.scope | capture("(^| )cli=(?<v>[^ ]*)")][0].v
                       | if . == null then null else split(",") | map(select(test("^[a-z]+$"))) end)}
           else {src: "rows", ids: [$recent[] | select(.agent_box == $b) | .agent_id], kb: (if $b == $here then $herekb else null end),
                 clis: (if $b == $here then $hereclis else null end)}
           end) as $x
        | ($x.ids | unique) as $u
        | {box: $b, here: ($b == $here), live: ($x.src != "rows" or ($u | length) > 0),
           busy: ([$u[] | select(seat | not)] | length), busy_ids: [$u[] | select(seat | not)], seats: ([$u[] | select(seat)] | length),
           clean_ids: ($x.clean // []), mem: ($x.kb | gb), mem_kb: $x.kb, clis: $x.clis, src: $x.src})' <<<"$1"
}

# Publish THIS box's load as its BOX-0 row, so the other boxes read real
# activity, free memory, its active CI runner jobs (ci=<N>,
# lib/bash/funcs/spl-box-ci.func.sh) and its vendors' weekly usage (wk=,
# lib/bash/funcs/spl-box-quota.func.sh) here. Only in a fleet, with the hub
# answering and the panes read; at most once per LANE_BOX_ROW_S (300 s), but at
# once when the CI job count changed. Best effort: a refusal is one line on
# stderr, never the map's exit code.
spl_lane_box_report() {  # ROWS LIVE_HERE LOAD
  [[ "$LANE_MODE" == hub && "$LANE_HUB_STATE" == ok && "${2:-null}" != null ]] || return 0
  local age was ci scope out id wk
  ci="$(spl_box_ci_jobs)"
  read -r age was < <(jq -r --arg id "$LANE_BOX_ROW_ID" --arg b "$LANE_BOX" \
    '[.[] | select(.agent_id == $id and .agent_box == $b and .state == "live")] | min_by(.age_s)
     | if . == null then "-1 -" else "\(.age_s) \((.scope // "") | [capture("(^| )ci=(?<n>[0-9]+)")][0].n // "0")" end' <<<"$1")
  [[ "$age" =~ ^[0-9]+$ ]] && (( age < ${LANE_BOX_ROW_S:-300} )) && [[ "$was" == "$ci" ]] && return 0
  declare -F spl_box_quota_here >/dev/null ||
    source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-box-quota.func.sh"
  wk="$(spl_box_quota_here)"
  # ci=<N> only while N > 0, cli=<kinds> ("-" none, left out when unknown)
  # and wk=<kind>:<pct>,... (left out when no pane shows one), before live=:
  # the cut below never drops them
  scope="$(jq -r --arg b "$LANE_BOX" --argjson ids "$2" --arg ci "$ci" --arg wk "$wk" \
    '.[] | select(.box == $b) | "mem_kb=\(.mem_kb // "?")\(if $ci == "0" then "" else " ci=\($ci)" end)\(
      if .clis == null then "" elif (.clis | length) == 0 then " cli=-" else " cli=\(.clis | join(","))" end)\(
      if $wk == "" then "" else " wk=\($wk)" end) live=\($ids | join(","))"' <<<"$3")"
  scope="${scope:0:500}"
  # whole ids only: a cut one could name a shorter id that is not clean
  for id in $(spl_lane_clean_here "$1" "$2"); do
    (( ${#scope} + ${#id} + 8 <= 500 )) || break
    if [[ "$scope" == *" clean="* ]]; then scope+=",$id"; else scope+=" clean=$id"; fi
  done
  out="$(spl_lane_hub --fleet "$LANE_FLEET" --agent "$LANE_BOX_ROW_ID" --box "$LANE_BOX" --scope "$scope" --state live 2>&1)" ||
    do_log "INFO the load of $LANE_BOX was not published ($LANE_BOX_ROW_ID@$LANE_BOX): $(tail -1 <<<"$out")" >&2
  return 0
}

# The BOX-0 row without a spawn (c-615): the lane map runs only on spawns
# and checks, so a box that spawned nothing for an hour aged past
# LANE_BOX_ROW_MAX_S and read `(no live row)` on every other box, its live
# lanes invisible. The box-stats cron calls this every 5 min: one hub read,
# then spl_lane_box_report as the map writes it (same row, same LANE_BOX_ROW_S
# rate limit). Needs spl_lane_init first. Best effort, always 0.
spl_lane_box_refresh() {  # LIVE_HERE (JSON array or null)
  [[ "$LANE_MODE" == hub && "${1:-null}" != null ]] || return 0
  local hub_json rows
  hub_json="$(spl_lane_hub --fleet "$LANE_FLEET" 2>/dev/null)" && jq -e '.lanes | type == "array"' >/dev/null 2>&1 <<<"$hub_json" ||
    { do_log "INFO the hub did not answer: the BOX-0 row of $LANE_BOX was not refreshed" >&2; return 0; }
  LANE_HUB_STATE=ok
  rows="$(spl_lane_merge "$hub_json" '[]')" || return 0
  spl_lane_box_report "$rows" "$1" "$(spl_lane_load "$rows" "$1" "$(spl_lane_clis_here)")"
}

# This box's hardware sample for the hub's history (rdb 0117), posted by
# do_post_box_stats every 5 min from the box-stats cron (the lane map runs only
# on spawns and checks, so its BOX-0 tick is no clock; that cron also keeps the
# BOX-0 row fresh, spl_lane_box_refresh).
# As one JSON object: /proc/loadavg (LANE_LOADAVG), nproc
# (LANE_NPROC), /proc/meminfo (LANE_MEMINFO), the live agent count and the
# disks (spl_lane_box_disks). Fails when load, cpus or memory cannot be read,
# so nothing half-read is sent; unreadable disks are [].
spl_lane_box_sample() {  # LIVE_HERE (JSON array)
  local l1 l5 l15 cpus mem total avail swap disks
  read -r l1 l5 l15 _ 2>/dev/null <"${LANE_LOADAVG:-/proc/loadavg}" || return 1
  cpus="${LANE_NPROC:-$(nproc 2>/dev/null)}"
  mem="$(awk '$1 ~ /^(MemTotal|MemAvailable|SwapTotal|SwapFree):$/ {v[$1] = $2}
    END {if (("MemTotal:" in v) && ("MemAvailable:" in v)) print v["MemTotal:"], v["MemAvailable:"], v["SwapTotal:"] - v["SwapFree:"]}' \
    "${LANE_MEMINFO:-/proc/meminfo}" 2>/dev/null)"
  [[ "$l1 $l5 $l15" =~ ^[0-9.]+\ [0-9.]+\ [0-9.]+$ && "$cpus" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+\ [0-9]+\ -?[0-9]+$ ]] || return 1
  read -r total avail swap <<<"$mem"
  (( swap < 0 )) && swap=0
  disks="$(spl_lane_box_disks)"
  jq -n -c --arg b "$LANE_BOX" --argjson l1 "$l1" --argjson l5 "$l5" --argjson l15 "$l15" --argjson c "$cpus" \
    --argjson t "$total" --argjson a "$avail" --argjson s "$swap" --argjson ids "${1:-[]}" --argjson d "$disks" \
    '{box: $b, load1: $l1, load5: $l5, load15: $l15, cpus: $c, mem_total_kb: $t, mem_avail_kb: $a,
      swap_used_kb: $s, agents_live: ($ids | length), disks: $d}'
}

# The real filesystems as [{mount, total_kb, avail_kb, used_kb}] (rdb 0121):
# POSIX df in kB minus the memory, image and EFI-variable mounts, one row per mount, at
# most 16 (the hub's cap), under a timeout (a hung network mount must not hold
# the tick). used_kb is df's Used: df's Use% is used / (used + avail), and
# total - avail would also count the root-reserved blocks (c-542: sat / read
# 47% for df's 45%); a row whose Used is not a number goes without it.
# LANE_DF_CMD replaces df in the tests. [] when df prints nothing usable.
spl_lane_box_disks() {
  local out
  if [[ -n "${LANE_DF_CMD:-}" ]]; then out="$($LANE_DF_CMD 2>/dev/null)"
  else out="$(timeout 10 df -kP -x tmpfs -x devtmpfs -x overlay -x squashfs -x efivarfs 2>/dev/null)"; fi
  awk 'NR > 1 && $2 ~ /^[0-9]+$/ && $4 ~ /^[0-9]+$/ {
         m = $6; for (i = 7; i <= NF; i++) m = m " " $i
         u = ($3 ~ /^[0-9]+$/) ? $3 : ""
         if (m ~ /^\// && !(m in seen)) { seen[m] = 1; printf "%s\t%s\t%s\t%s\n", m, $2, $4, u } }' <<<"$out" |
    head -n 16 | jq -R -s -c 'split("\n") | map(select(length > 0) | split("\t")
      | {mount: .[0], total_kb: (.[1] | tonumber), avail_kb: (.[2] | tonumber)}
        + (if (.[3] // "") == "" then {} else {used_kb: (.[3] | tonumber)} end))'
}

# The lanes live on THIS box (LIVE_HERE) whose row has `files: []` and whose
# worktree here is clean (spl_lane_wt_changes prints nothing): they edit
# nothing, so --check on the other boxes need not call them unknown. One id
# per line. A lane whose worktree is not found here is not clean.
spl_lane_clean_here() {  # ROWS LIVE_HERE (JSON array)
  local scan
  scan="$(spl_lane_wt_scan "$(jq -c --arg b "$LANE_BOX" --argjson ids "${2:-[]}" \
    '[.[] | select(.state == "live" and .agent_box == $b and (.files | length) == 0 and (.agent_id as $a | $ids | index($a)) != null)]' <<<"$1")")"
  jq -r 'to_entries[] | select(.value | length == 0) | .key' <<<"$scan"
}

# The worktree of lane ID here: <top>-wt/<ID> of a LANE_REPO_DIRS repo, or
# <repo>-wt/<ID> beside it for the row's REPO. Fails when there is none.
spl_lane_wt_dir() {  # ID REPO
  local top d
  for top in $(spl_lane_repo_tops); do
    for d in "${top}-wt/$1" ${2:+"$(dirname "$top")/$2-wt/$1"}; do
      [[ -e "$d/.git" ]] && { printf '%s\n' "$d"; return 0; }
    done
  done
  return 1
}

# The paths a worktree changes, one per line: its commits not on the
# default branch (origin/HEAD, else origin/master or origin/main), its
# uncommitted edits and its untracked files. Fails when git cannot tell.
spl_lane_wt_changes() {  # WT
  local base b out
  base="$(git -C "$1" symbolic-ref -q --short refs/remotes/origin/HEAD 2>/dev/null)"
  for b in origin/master origin/main; do
    [[ -z "$base" ]] && git -C "$1" rev-parse -q --verify "$b^{commit}" >/dev/null 2>&1 && base="$b"
  done
  [[ -n "$base" ]] || return 1
  out="$(timeout 20 git -C "$1" diff --name-only "$base...HEAD" && timeout 20 git -C "$1" diff --name-only HEAD &&
    timeout 20 git -C "$1" ls-files --others --exclude-standard)" || return 1
  sort -u <<<"$out" | sed '/^$/d'
}

# {"<id>": [changed paths, at most 200]} for the rows of this box in ROWS
# (a JSON array) whose worktree is here; a lane git cannot read is left out.
spl_lane_wt_scan() {  # ROWS
  local id repo wt paths
  while IFS=$'\t' read -r id repo; do
    wt="$(spl_lane_wt_dir "$id" "$repo")" || continue
    paths="$(spl_lane_wt_changes "$wt")" || continue
    jq -R -s -c --arg id "$id" '{($id): (split("\n") | map(select(length > 0)) | .[0:200])}' <<<"$paths"
  done < <(jq -r --arg b "$LANE_BOX" '.[] | select(.agent_box == $b) | [.agent_id, .repo] | @tsv' <<<"$1") | jq -s -c 'add // {}'
}

# One line per box above the table, e.g. `BOX box-a (here)  busy 8  seats 1  mem 12.3G`;
# a box read from its rows (no BOX-0 row) says so.
spl_lane_load_header() {
  jq -r '.[] | "BOX \(.box)\(if .here then " (here)" else "" end)  busy \(.busy)  seats \(.seats)  mem \(.mem)\(if .live | not then "  (no live row)" elif .src == "rows" then "  (rows < 2h)" else "" end)"' <<<"$1"
}

# Exit 3 when a live lane of another agent lists a path that overlaps one in
# LANE_CHECK (one is the other, or contains it at a / boundary). A trailing
# `/*` or `/**` (a row written as `internal/store/*`) is that directory: as a
# literal it matched nothing, so a file under it read free.
# A build lane of another agent, live on its box NOW (busy_ids of the load:
# its pane here, its box's BOX-0 row there, else its row younger than 2 h),
# with `files: []` cannot say `owned`, so `free` would be a guess (two
# near-collisions, 2026-10-10). Such a lane:
#   - worktree on this box: its changed paths (spl_lane_wt_changes) stand in
#     for its files, an overlap is exit 3 `... (changed in its worktree; no
#     files recorded)`; a clean worktree edits nothing and does not count
#   - on another box: not counted when that box's BOX-0 row lists it clean
#   - else exit 4, one `unknown: <ID>@<box> <branch> ...` line per lane
#     instead of `free`; a caller that reads any non-zero as taken stays safe
# Seats (001-003, lease.conf ids) run the fleet and never count; nor do old
# `live` rows with no pane.
spl_lane_check() {  # ROWS LOAD (spl_lane_load)
  local rows="$1" load="${2:-[]}" cand hits unknown chf
  cand="$(jq -c --arg me "${LANE_AGENT:-}" --argjson load "$load" '
    [.[] | select(.state == "live" and .agent_id != $me and (.files | length) == 0) as $l
     | select(any($load[]; .box == $l.agent_box and ((.busy_ids // []) | index($l.agent_id)) != null))]' <<<"$rows")"
  chf="$(mktemp)" || return 1
  spl_lane_wt_scan "$cand" >"$chf" || echo '{}' >"$chf"
  rows="$(jq -c --slurpfile ch "$chf" --arg here "$LANE_BOX" '
    map(if .state == "live" and (.files | length) == 0 and .agent_box == $here and $ch[0][.agent_id] != null
        then .files = $ch[0][.agent_id] | .from_wt = true else . end)' <<<"$rows")"
  hits="$(jq -r --arg me "${LANE_AGENT:-}" --arg want "$LANE_CHECK" '
    def norm: sub("^\\./"; "") | sub("(/+\\*{1,2})+/*$"; "") | sub("/+$"; "");
    def over($a; $b): $a == $b or ($a | startswith($b + "/")) or ($b | startswith($a + "/"));
    ($want | split(",") | map(norm) | map(select(length > 0))) as $w
    | .[] | select(.state == "live" and .agent_id != $me) as $l
    | $l.files[] | norm as $f
    | $w[] | select(over(.; $f))
    | "\(.) owned by \($l.agent_id)@\($l.agent_box) \($l.branch)\(if $l.from_wt then " (changed in its worktree; no files recorded)" else "" end)"' <<<"$rows" | sort -u)"
  unknown="$(jq -r --slurpfile ch "$chf" --arg here "$LANE_BOX" --argjson load "$load" '
    .[] | select((.agent_box == $here and $ch[0][.agent_id] != null) | not) as $l
    | select(any($load[]; .box == $l.agent_box and ((.clean_ids // []) | index($l.agent_id)) != null) | not)
    | "unknown: \(.agent_id)@\(.agent_box) \(.branch) has no files recorded; ask it or read its brief"' <<<"$cand" | sort -u)"
  rm -f "$chf"
  if [[ "$LANE_HUB_STATE" == unreachable ]]; then
    do_log "WARN the collision check saw this machine only (the hub did not answer)"
    spl_lane_local_only_line
  fi
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits"
    do_log "WARN $(wc -l <<<"$hits") path(s) overlap another live lane: keep the new scope disjoint, or talk to that agent first"
    return 3
  fi
  if [[ -n "$unknown" ]]; then
    printf '%s\n' "$unknown"
    do_log "WARN no live lane lists $LANE_CHECK, but $(wc -l <<<"$unknown") live lane(s) record no files: their scope is unknown, not free"
    return 4
  fi
  if [[ "$LANE_HUB_STATE" == unreachable ]]; then
    do_log "WARN no lane on THIS machine owns $LANE_CHECK; the other machines were not read: not free (exit 5)"
    return 5
  fi
  echo free
  do_log "INFO no live lane of another agent owns $LANE_CHECK"
}

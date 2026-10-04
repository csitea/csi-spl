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
# @description The default table hides the rows 2 h old or older, and those with
# @description no age while the hub answered, behind a footer
# @description `N older rows hidden (--all)`; LANE_ALL=1 shows every row.
# @param LANE_FLEET (optional) - the fleet; default LEASE_FLEET (env, then <spool root>/dispatch/lease.conf)
# @param LANE_ENV / LANE_TENANT (optional) - the hub env (dev|prd|self) and the tenant holding the map; default LEASE_ENV / LEASE_TENANT
# @param LANE_DESK_BOX (optional) - the pinned desk box whose key signs the calls; default LEASE_DESK_BOX, then spl_desk_box_default
# @param LANE_FORMAT (optional) - table (default) or json
# @param LANE_ALL (optional) - 1 also lists done rows (the hub keeps them a week) and the older rows the table hides
# @param LANE_CHECK (optional) - comma-separated paths the caller is about to own; exit 3 on an overlap with another live lane
# @param LANE_AGENT (optional) - the caller's own id, skipped by LANE_CHECK
# @param LANE_REPO_DIRS (optional) - space-separated repos whose local worktrees join the map; default the repo holding this tree
# @param LANE_HUB_CMD (optional, tests) - replaces the hub call: gets `lane <args>`, prints the hub's answer
# @param LANE_BOX_ROW_S (optional) - rewrite this box's BOX-0 load row when it is this old, default 300 s
# @param LANE_BOX_ROW_MAX_S (optional) - a box's BOX-0 row older than this is not read, default 3600 s
# @param LANE_PANES_CMD (optional, tests) - replaces the tmux read: prints `<pane_dead> <window name>` lines
# @example ./run -a do_spl_lane_map
# @example LANE_CHECK=csi-spl-orc/src/bash/run/,csi-spl-doc/specs/058-multi-machine-fleet/ LANE_AGENT=CLE-77920 ./run -a do_spl_lane_map
# @example LANE_FORMAT=json LANE_ALL=1 ./run -a do_spl_lane_map

declare -F spl_desk_box_default >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-box.func.sh"

do_spl_lane_map() {
  local rows hub_json="" fmt="${LANE_FORMAT:-table}" rc=0 live_here load
  [[ "$fmt" =~ ^(table|json)$ ]] || { do_log "FATAL LANE_FORMAT must be table or json"; return 1; }
  spl_lane_init || return 1
  if [[ "$LANE_MODE" == hub ]]; then
    if hub_json="$(spl_lane_hub --fleet "$LANE_FLEET" 2>"${LANE_ERR:-/dev/null}")" && jq -e '.lanes | type == "array"' >/dev/null 2>&1 <<<"$hub_json"; then
      LANE_HUB_STATE=ok
    else
      LANE_HUB_STATE=unreachable hub_json=""
      do_log "WARN the hub did not answer: this map shows only this machine's lanes (local worktrees)"
    fi
  fi
  rows="$(spl_lane_merge "${hub_json:-{\"lanes\":[]\}}" "$(spl_lane_local_rows)")" || { do_log "FATAL cannot merge the lane rows"; return 1; }
  live_here="$(spl_lane_live_here)"
  load="$(spl_lane_load "$rows" "$live_here")"
  spl_lane_box_report "$rows" "$live_here" "$load"
  # the box rows feed the load only: they are no lane
  rows="$(jq -c --arg b "$LANE_BOX_ROW_ID" '[.[] | select(.agent_id != $b)]' <<<"$rows")"
  [[ "${LANE_ALL:-0}" == 1 ]] || rows="$(jq -c '[.[] | select(.state == "live")]' <<<"$rows")"

  if [[ "$fmt" == json ]]; then
    jq -c --arg f "${LANE_FLEET:-}" --arg h "$LANE_HUB_STATE" --argjson load "$load" \
      '{fleet: $f, hub: $h, load: $load, lanes: .}' <<<"$rows"
  elif [[ -z "${LANE_CHECK:-}" ]]; then
    spl_lane_load_header "$load"
    spl_lane_table_recent "$rows"
  fi
  if [[ -n "${LANE_CHECK:-}" ]]; then
    spl_lane_check "$rows" || rc=$?
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
  done < <(grep -E '^LEASE_(FLEET|ENV|TENANT|DESK_BOX)=[a-z0-9][a-z0-9-]*$' "$f")
  return 0
}

# `spool lane <args>` as this machine's desk box, under a timeout.
spl_lane_hub() { spl_lane_spool lane "$@"; }

# `spool <verb> <args>` as this machine's desk box, under a timeout.
spl_lane_spool() {
  if [[ -n "${LANE_HUB_CMD:-}" ]]; then "$LANE_HUB_CMD" "$@"; return; fi
  SPOOL_ROOT="$LANE_DESK_DIR/spool" SPOOL_KEYS_DIR="$LANE_DESK_DIR/keys" SPOOL_BOX_ID="$LANE_DESK_BOX" \
    SPOOL_HUB_URL="$SPL_HUB_URL" SPOOL_TENANT="$LANE_TENANT" timeout "${LANE_TIMEOUT:-30}" "$SPL_SPOOL" "$@"
}

# This machine's lanes as rows: every worktree at <repo>-wt/<ID> of the repos
# in LANE_REPO_DIRS. A JSON array.
spl_lane_local_rows() {
  local dirs="${LANE_REPO_DIRS:-}" d top wt br id
  if [[ -z "$dirs" ]]; then
    dirs="$(git -C "${PROJ_PATH:-.}" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
    dirs="${dirs%/.git}"
  fi
  for d in $dirs; do
    top="$(git -C "$d" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || continue
    top="${top%/.git}"
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
spl_lane_table_recent() {
  local shown hidden
  if [[ "${LANE_ALL:-0}" == 1 ]]; then spl_lane_table "$1"; return; fi
  shown="$(jq -c --argjson max "${LANE_RECENT_S:-7200}" --arg h "$LANE_HUB_STATE" \
    '[.[] | select((.age_s >= 0 and .age_s < $max) or (.age_s < 0 and $h != "ok"))]' <<<"$1")"
  spl_lane_table "$shown"
  hidden=$(( $(jq length <<<"$1") - $(jq length <<<"$shown") ))
  (( hidden == 0 )) || echo "$hidden older rows hidden (--all)"
}

# The reserved id of a box's LOAD row in the lane map: one row per box,
# BOX-0@<box>, scope `mem_kb=<MemAvailable> live=<id>,<id>,...` - the agents
# with a live tmux pane on that box and its free memory, as that box itself
# read them. The hub stores it like any lane (no field of its own, no hub
# change); this action writes it (spl_lane_box_report) and the map never
# shows it as a lane. A legacy-grammar id no agent can hold.
LANE_BOX_ROW_ID=BOX-0

# The agent ids with a live pane on THIS box, as a JSON array, from the tmux
# window names (the id is their first token, as the 40-window ceiling counts
# them; spool_id_of_window); dead panes do not count. null when tmux cannot
# be read (no server): the load then falls back to the rows.
spl_lane_live_here() {
  local out user sock dead name id
  local -a tm
  if [[ -n "${LANE_PANES_CMD:-}" ]]; then
    out="$($LANE_PANES_CMD 2>/dev/null)" || { echo null; return 0; }
  else
    user="${SPOOL_BOX_USER:-$(stat -c %U "${SPOOL_ROOT:-/var/spool-hub}" 2>/dev/null)}"
    case "$user" in ''|root|UNKNOWN) user="$(id -un)" ;; esac
    sock="${SPOOL_TMUX_SOCKET:-/tmp/tmux-$(id -u "$user" 2>/dev/null || id -u)/default}"
    tm=(tmux -u -S "$sock")
    [[ "$(id -un)" == "$user" ]] || tm=(sudo -n -u "$user" tmux -u -S "$sock")
    out="$(timeout 10 "${tm[@]}" list-panes -a -F '#{pane_dead} #{window_name}' 2>/dev/null)" || { echo null; return 0; }
  fi
  declare -F spool_id_of_window_var >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  while read -r dead name; do
    [[ "$dead" == 0 ]] || continue
    spool_id_of_window_var id "$name"
    [[ -n "$id" ]] && printf '%s\n' "$id"
  done <<<"$out" | sort -u | jq -R -s -c 'split("\n") | map(select(length > 0))'
}

# The load per box, as a JSON array of
# {box, here, live, busy, seats, mem, mem_kb, src}: the agents live on the box
# NOW, split into busy (build lanes) and seats (001-003 and the ids lease.conf
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
# BOX-0 row), "?" unknown. The boxes: this one first, then the lease.conf
# rankings (LEASE_PRIORITY*), then any other box a row names.
# spawn-window.sh places a lane by it; the table prints it as its header.
spl_lane_load() {  # ROWS (every merged row, done and BOX-0 too) LIVE_HERE (JSON array or null)
  local f="${SPOOL_ROOT:-/var/spool-hub}/dispatch/lease.conf" conf_boxes="" seat_ids="" kb
  if [[ -r "$f" ]]; then
    conf_boxes="$(sed -n 's/^LEASE_PRIORITY[A-Z_]*=\([a-z0-9,-]*\)$/\1/p' "$f" | tr ',' '\n' | grep -E '^[a-z0-9][a-z0-9-]{0,31}$')"
    seat_ids="$(sed -n 's/^LEASE_\(MASTER\|FAILOVER\|ORCH\)=\([A-Za-z0-9-]*\)$/\2/p' "$f")"
  fi
  kb="$(awk '$1 == "MemAvailable:" {print $2; exit}' "${LANE_MEMINFO:-/proc/meminfo}" 2>/dev/null)"
  [[ "$kb" =~ ^[0-9]+$ ]] || kb=null
  jq -c --arg here "$LANE_BOX" --argjson herekb "$kb" --argjson herelive "${2:-null}" --arg h "$LANE_HUB_STATE" \
    --argjson max "${LANE_RECENT_S:-7200}" --argjson boxmax "${LANE_BOX_ROW_MAX_S:-3600}" --arg brid "$LANE_BOX_ROW_ID" \
    --arg conf "$conf_boxes" --arg seats "$seat_ids" '
    ($seats | split("\n") | map(select(length > 0))) as $ids
    | def seat: test("^[A-Za-z]+-00[1-3]$") or (. as $a | $ids | index($a) != null);
      def gb: if . == null then "?" else (. / 104857.6 | round) as $t | "\($t / 10 | floor).\($t % 10)G" end;
      def field($k): [capture($k + "=(?<v>[^ ]*)")][0].v // "";
    [.[] | select(.agent_id == $brid and .state == "live" and .age_s >= 0 and .age_s < $boxmax)] as $reports
    | [.[] | select(.agent_id != $brid)] as $lanes
    | [$lanes[] | select(.state == "live" and ((.age_s >= 0 and .age_s < $max) or (.age_s < 0 and $h != "ok")))] as $recent
    | ([$here] + ($conf | split("\n")) + [$recent[].agent_box] + [$reports[].agent_box] | map(select(length > 0))) as $all
    | reduce $all[] as $b ([]; if index($b) then . else . + [$b] end)
    | map(. as $b
        | ([$reports[] | select(.agent_box == $b)] | sort_by(.age_s) | first) as $rep
        | (if $b == $here and $herelive != null then {src: "panes", ids: $herelive, kb: $herekb}
           elif $rep != null then
             [$lanes[] | select(.agent_box == $b and .age_s >= 0 and .age_s < $rep.age_s)] as $since
             | {src: "box",
                ids: (($rep.scope | field("live") | split(",") | map(select(length > 0)))
                      + [$since[] | select(.state == "live") | .agent_id]
                      - [$since[] | select(.state == "done") | .agent_id]),
                kb: ($rep.scope | field("mem_kb") | if test("^[0-9]+$") then tonumber else null end)}
           else {src: "rows", ids: [$recent[] | select(.agent_box == $b) | .agent_id], kb: (if $b == $here then $herekb else null end)}
           end) as $x
        | ($x.ids | unique) as $u
        | {box: $b, here: ($b == $here), live: ($x.src != "rows" or ($u | length) > 0),
           busy: ([$u[] | select(seat | not)] | length), seats: ([$u[] | select(seat)] | length),
           mem: ($x.kb | gb), mem_kb: $x.kb, src: $x.src})' <<<"$1"
}

# Publish THIS box's load as its BOX-0 row, so the other boxes read real
# activity and free memory here. Only in a fleet, with the hub answering and
# the panes read; at most once per LANE_BOX_ROW_S (300 s). Best effort: a
# refusal is one line on stderr, never the map's exit code.
spl_lane_box_report() {  # ROWS LIVE_HERE LOAD
  [[ "$LANE_MODE" == hub && "$LANE_HUB_STATE" == ok && "${2:-null}" != null ]] || return 0
  local age scope out
  age="$(jq -r --arg id "$LANE_BOX_ROW_ID" --arg b "$LANE_BOX" \
    '[.[] | select(.agent_id == $id and .agent_box == $b and .state == "live") | .age_s] | min // -1' <<<"$1")"
  [[ "$age" =~ ^[0-9]+$ ]] && (( age < ${LANE_BOX_ROW_S:-300} )) && return 0
  scope="$(jq -r --arg b "$LANE_BOX" --argjson ids "$2" \
    '.[] | select(.box == $b) | "mem_kb=\(.mem_kb // "?") live=\($ids | join(","))"' <<<"$3")"
  scope="${scope:0:500}"
  out="$(spl_lane_hub --fleet "$LANE_FLEET" --agent "$LANE_BOX_ROW_ID" --box "$LANE_BOX" --scope "$scope" --state live 2>&1)" ||
    do_log "INFO the load of $LANE_BOX was not published ($LANE_BOX_ROW_ID@$LANE_BOX): $(tail -1 <<<"$out")" >&2
  return 0
}

# This box's hardware sample for the hub's history (rdb 0117), posted by
# do_post_box_stats every 5 min from the box-stats cron (the lane map runs only
# on spawns and checks, so its BOX-0 tick is no clock).
# As one JSON object: /proc/loadavg (LANE_LOADAVG), nproc
# (LANE_NPROC), /proc/meminfo (LANE_MEMINFO) and the live agent count. Fails
# when a source cannot be read, so nothing half-read is sent.
spl_lane_box_sample() {  # LIVE_HERE (JSON array)
  local l1 l5 l15 cpus mem total avail swap
  read -r l1 l5 l15 _ 2>/dev/null <"${LANE_LOADAVG:-/proc/loadavg}" || return 1
  cpus="${LANE_NPROC:-$(nproc 2>/dev/null)}"
  mem="$(awk '$1 ~ /^(MemTotal|MemAvailable|SwapTotal|SwapFree):$/ {v[$1] = $2}
    END {if (("MemTotal:" in v) && ("MemAvailable:" in v)) print v["MemTotal:"], v["MemAvailable:"], v["SwapTotal:"] - v["SwapFree:"]}' \
    "${LANE_MEMINFO:-/proc/meminfo}" 2>/dev/null)"
  [[ "$l1 $l5 $l15" =~ ^[0-9.]+\ [0-9.]+\ [0-9.]+$ && "$cpus" =~ ^[0-9]+$ && "$mem" =~ ^[0-9]+\ [0-9]+\ -?[0-9]+$ ]] || return 1
  read -r total avail swap <<<"$mem"
  (( swap < 0 )) && swap=0
  jq -n -c --arg b "$LANE_BOX" --argjson l1 "$l1" --argjson l5 "$l5" --argjson l15 "$l15" --argjson c "$cpus" \
    --argjson t "$total" --argjson a "$avail" --argjson s "$swap" --argjson ids "${1:-[]}" \
    '{box: $b, load1: $l1, load5: $l5, load15: $l15, cpus: $c, mem_total_kb: $t, mem_avail_kb: $a,
      swap_used_kb: $s, agents_live: ($ids | length)}'
}

# One line per box above the table, e.g. `BOX box-a (here)  busy 8  seats 1  mem 12.3G`;
# a box read from its rows (no BOX-0 row) says so.
spl_lane_load_header() {
  jq -r '.[] | "BOX \(.box)\(if .here then " (here)" else "" end)  busy \(.busy)  seats \(.seats)  mem \(.mem)\(if .live | not then "  (no live row)" elif .src == "rows" then "  (rows < 2h)" else "" end)"' <<<"$1"
}

# Exit 3 when a live lane of another agent lists a path that overlaps one in
# LANE_CHECK (one is the other, or contains it at a / boundary).
spl_lane_check() {
  local hits
  hits="$(jq -r --arg me "${LANE_AGENT:-}" --arg want "$LANE_CHECK" '
    def norm: sub("^\\./"; "") | sub("/+$"; "");
    def over($a; $b): $a == $b or ($a | startswith($b + "/")) or ($b | startswith($a + "/"));
    ($want | split(",") | map(norm) | map(select(length > 0))) as $w
    | .[] | select(.state == "live" and .agent_id != $me) as $l
    | $l.files[] | norm as $f
    | $w[] | select(over(.; $f))
    | "\(.) owned by \($l.agent_id)@\($l.agent_box) \($l.branch)"' <<<"$1")"
  if [[ "$LANE_HUB_STATE" == unreachable ]]; then
    do_log "WARN the collision check saw this machine only (the hub did not answer)"
  fi
  if [[ -n "$hits" ]]; then
    printf '%s\n' "$hits"
    do_log "WARN $(wc -l <<<"$hits") path(s) overlap another live lane: keep the new scope disjoint, or talk to that agent first"
    return 3
  fi
  echo free
  do_log "INFO no live lane of another agent owns $LANE_CHECK"
}

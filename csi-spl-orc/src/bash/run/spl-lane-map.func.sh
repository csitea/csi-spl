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
# @example ./run -a do_spl_lane_map
# @example LANE_CHECK=csi-spl-orc/src/bash/run/,csi-spl-doc/specs/058-multi-machine-fleet/ LANE_AGENT=CLE-77920 ./run -a do_spl_lane_map
# @example LANE_FORMAT=json LANE_ALL=1 ./run -a do_spl_lane_map

declare -F spl_desk_box_default >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/../../../lib/bash/funcs/spl-desk-box.func.sh"

do_spl_lane_map() {
  local rows hub_json="" fmt="${LANE_FORMAT:-table}" rc=0
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
  [[ "${LANE_ALL:-0}" == 1 ]] || rows="$(jq -c '[.[] | select(.state == "live")]' <<<"$rows")"

  if [[ "$fmt" == json ]]; then
    jq -c --arg f "${LANE_FLEET:-}" --arg h "$LANE_HUB_STATE" '{fleet: $f, hub: $h, lanes: .}' <<<"$rows"
  elif [[ -z "${LANE_CHECK:-}" ]]; then
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
spl_lane_hub() {
  if [[ -n "${LANE_HUB_CMD:-}" ]]; then "$LANE_HUB_CMD" lane "$@"; return; fi
  SPOOL_ROOT="$LANE_DESK_DIR/spool" SPOOL_KEYS_DIR="$LANE_DESK_DIR/keys" SPOOL_BOX_ID="$LANE_DESK_BOX" \
    SPOOL_HUB_URL="$SPL_HUB_URL" SPOOL_TENANT="$LANE_TENANT" timeout "${LANE_TIMEOUT:-30}" "$SPL_SPOOL" lane "$@"
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
spl_lane_merge() {
  jq -c -n --argjson hub "$1" --argjson loc "$2" '
    ($hub.lanes // [] | map(. + {src: "hub"})) as $h
    | ($h | map({key: .agent_id, value: .}) | from_entries) as $byid
    | $h + [ $loc[] | select(($byid[.agent_id] // null) == null) ]
    | ([$loc[] | .agent_id]) as $here
    | map(. as $r | if $r.src == "hub" and ($here | index($r.agent_id)) != null then .src = "hub+local" else . end)'
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

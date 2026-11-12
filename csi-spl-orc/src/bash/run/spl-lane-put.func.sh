#!/bin/bash
# @description Write one agent's row of the fleet-wide lane map on the hub
# @description (CLE-77920, specs/058 G4; read it with do_spl_lane_map). The spawn
# @description path calls it with LANE_STATE=live, exit-clean with LANE_STATE=done.
# @description A done write keeps the row's other fields from the hub unless
# @description given. Without a fleet (no LANE_FLEET / lease.conf LEASE_FLEET)
# @description there is no shared map: it logs that and exits 0. A hub that does
# @description not answer is exit 2 (the callers treat the write as best effort).
# @description A retired id (spec 061) takes one write past its cutoff: LANE_STATE=done
# @description on a row it already has (SPL-4962). Live stays refused. A done write
# @description of an id the hub holds no row of on its box, where the hub answered
# @description with rows of that box, is exit 6: nothing to close (SPL-5340), with
# @description or without LANE_TOPIC: a done never mints a row (SPL-5344).
# @param LANE_AGENT (required) - the agent id, e.g. c-042; its box is LANE_BOX (default spl_desk_box_default)
# @param LANE_STATE (optional) - live (default) or done
# @param LANE_REPO / LANE_BRANCH / LANE_SCOPE / LANE_TOPIC (optional) - the row's fields; the scope is cut to one line of 500 bytes
# @param LANE_ISSUE (optional) - the lane's issue key, e.g. SPL-12 (spec 153 3.4); a done write keeps the row's key
# @param LANE_ORIGIN_ISSUE (optional) - the issue the lane came from (spec 153 3.12); a done write keeps the row's key
# @param LANE_FILES (optional) - comma-separated paths the agent owns (at most 50)
# @param LANE_FLEET LANE_ENV LANE_TENANT LANE_DESK_BOX LANE_HUB_CMD (optional) - as do_spl_lane_map
# @example LANE_AGENT=CLE-77920 LANE_REPO=csi-spl LANE_BRANCH=CLE-77920-lane-map LANE_SCOPE='fleet lane map' LANE_FILES=csi-spl-orc/src/bash/run/spl-lane-map.func.sh ./run -a do_spl_lane_put
# @example LANE_AGENT=CLE-77920 LANE_STATE=done ./run -a do_spl_lane_put

declare -F spl_lane_init >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-map.func.sh"

do_spl_lane_put() {
  local state="${LANE_STATE:-live}" cur="" scope files retired=0
  declare -F spl_is_agent_id >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents/lib/spool-env.inc.sh"
  [[ "$state" =~ ^(live|done)$ ]] || { do_log "FATAL LANE_STATE must be live or done"; return 1; }
  # Same grammar as the Go agentid.Retired: the hub and `spool lane` take this write too
  if [[ "$state" == "done" && "${LANE_AGENT:-}" =~ ^(CLE|AGY|GRK|QWN)-[0-9]+$ ]] && ! spl_legacy_id_ok; then
    retired=1
  else
    spl_is_participant_id "${LANE_AGENT:-}" || { do_log "FATAL LANE_AGENT must be an agent id like c-042, got '${LANE_AGENT:-}'"; return 1; }
  fi
  spl_lane_init || return 1
  if [[ "$LANE_MODE" != hub ]]; then
    do_log "INFO no fleet (LANE_FLEET / LEASE_FLEET in lease.conf): the lane map is this machine's worktrees, nothing to write"
    return 0
  fi
  if [[ "$state" == "done" ]]; then
    # The row is <ID>@<box>, so one id can carry a row per box (an old
    # box-desk row next to the renamed one): read THIS box's row only, or
    # the box field comes back as two lines ("sat box-desk")
    local rows
    rows="$(spl_lane_hub --fleet "$LANE_FLEET" 2>/dev/null)"
    cur="$(jq -c --arg a "$LANE_AGENT" --arg b "$LANE_BOX" \
      '[.lanes[]? | select(.agent_id == $a and .agent_box == $b)] | first // empty' <<<"$rows" 2>/dev/null)"
    if (( retired )) && [[ -z "$cur" ]]; then
      do_log "FATAL no row of $LANE_AGENT@$LANE_BOX read from the hub: a retired id only closes a row it has"
      return 1
    fi
    # SPL-5340: the hub answered with rows of this box and none is the id's, so a
    # write would mint a row with no topic. The binary refuses that ("topic is
    # required", rdb 0264) before it calls the hub, so the same line follows an
    # unanswered read: only an answer with rows of this box tells "no row". An
    # answer with none (a wrong or renamed box) is "cannot tell", as rlc_no_row.
    # SPL-5344: a given LANE_TOPIC does not change it: a done closes a row, it
    # never mints one (a review lane's task names no discussion: bad_frame).
    if [[ -z "$cur" ]] &&
      jq -e --arg b "$LANE_BOX" '[.lanes[]? | select(.agent_box == $b)] | length > 0' <<<"$rows" >/dev/null 2>&1; then
      do_log "INFO no hub lane row of $LANE_AGENT on $LANE_BOX: nothing to close"
      return 6
    fi
  fi
  # lane_was <field>: that field of the hub row read above ("" without one);
  # a LANE_* set in the environment, even empty, wins over it
  lane_was() { jq -r --arg k "$1" '.[$k] // "" | if type == "array" then join(",") else . end' <<<"${cur:-{\}}"; }
  scope="${LANE_SCOPE-$(lane_was scope)}"
  scope="$(printf '%s' "$scope" | tr '\t\r\n' '   ' | tr -d '\000-\037\177' | cut -b 1-500)"
  files="${LANE_FILES-$(lane_was files)}"
  files="$(printf '%s' "$files" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | sed -n 1,50p | paste -sd, -)"
  local box="$LANE_BOX" out issue origin rc=0
  # --issue only with a key: a box spool binary built before it took the
  # flag still writes every key-less row
  issue="${LANE_ISSUE-$(lane_was issue_key)}"
  origin="${LANE_ORIGIN_ISSUE-$(lane_was origin_issue)}"
  [[ -n "$cur" ]] && box="$(lane_was agent_box)"
  [[ "$box" =~ ^[a-z0-9][a-z0-9-]{0,31}$ ]] || { do_log "FATAL lane $LANE_AGENT: the box must be ONE box id, got '$box'"; return 1; }
  local -a row=(--fleet "$LANE_FLEET" --agent "$LANE_AGENT" --box "$box"
    --repo "${LANE_REPO-$(lane_was repo)}" --branch "${LANE_BRANCH-$(lane_was branch)}"
    --scope "$scope" --files "$files" --topic "${LANE_TOPIC-$(lane_was topic)}" ${issue:+--issue "$issue"} --state "$state")
  out="$(spl_lane_hub "${row[@]}" ${origin:+--origin-issue "$origin"} 2>&1)" || rc=$?
  # A box binary built before the flag still writes the row, without the origin
  if (( rc != 0 )) && [[ -n "$origin" && "$out" == *"flag provided but not defined"* ]]; then
    do_log "WARN lane $LANE_AGENT: this box's spool binary takes no --origin-issue: the row is written without $origin"
    rc=0; out="$(spl_lane_hub "${row[@]}" 2>&1)" || rc=$?
  fi
  if (( rc != 0 )); then
    do_log "WARN lane $LANE_AGENT@$box not written ($state): $(tail -1 <<<"$out")"
    return 2
  fi
  do_log "OK lane $LANE_AGENT@$box $state in fleet $LANE_FLEET"
}

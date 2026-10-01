#!/bin/bash
# @description Write one agent's row of the fleet-wide lane map on the hub
# @description (CLE-77920, specs/058 G4; read it with do_spl_lane_map). The spawn
# @description path calls it with LANE_STATE=live, exit-clean with LANE_STATE=done.
# @description A done write keeps the row's other fields from the hub unless
# @description given. Without a fleet (no LANE_FLEET / lease.conf LEASE_FLEET)
# @description there is no shared map: it logs that and exits 0. A hub that does
# @description not answer is exit 2 (the callers treat the write as best effort).
# @param LANE_AGENT (required) - the agent id, e.g. CLE-77920; its box is LANE_BOX (default spl_desk_box_default)
# @param LANE_STATE (optional) - live (default) or done
# @param LANE_REPO / LANE_BRANCH / LANE_SCOPE / LANE_TOPIC (optional) - the row's fields; the scope is cut to one line of 500 bytes
# @param LANE_FILES (optional) - comma-separated paths the agent owns (at most 50)
# @param LANE_FLEET LANE_ENV LANE_TENANT LANE_DESK_BOX LANE_HUB_CMD (optional) - as do_spl_lane_map
# @example LANE_AGENT=CLE-77920 LANE_REPO=csi-spl LANE_BRANCH=CLE-77920-lane-map LANE_SCOPE='fleet lane map' LANE_FILES=csi-spl-orc/src/bash/run/spl-lane-map.func.sh ./run -a do_spl_lane_put
# @example LANE_AGENT=CLE-77920 LANE_STATE=done ./run -a do_spl_lane_put

declare -F spl_lane_init >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/spl-lane-map.func.sh"

do_spl_lane_put() {
  local state="${LANE_STATE:-live}" cur="" scope files
  [[ "${LANE_AGENT:-}" =~ ^[A-Z]{2,4}-[0-9]{1,9}$ ]] || { do_log "FATAL LANE_AGENT must be an agent id like CLE-07, got '${LANE_AGENT:-}'"; return 1; }
  [[ "$state" =~ ^(live|done)$ ]] || { do_log "FATAL LANE_STATE must be live or done"; return 1; }
  spl_lane_init || return 1
  if [[ "$LANE_MODE" != hub ]]; then
    do_log "INFO no fleet (LANE_FLEET / LEASE_FLEET in lease.conf): the lane map is this machine's worktrees, nothing to write"
    return 0
  fi
  if [[ "$state" == done ]]; then
    cur="$(spl_lane_hub --fleet "$LANE_FLEET" 2>/dev/null | jq -c --arg a "$LANE_AGENT" '.lanes[]? | select(.agent_id == $a)' 2>/dev/null)"
  fi
  # lane_was <field>: that field of the hub row read above ("" without one);
  # a LANE_* set in the environment, even empty, wins over it
  lane_was() { jq -r --arg k "$1" '.[$k] // "" | if type == "array" then join(",") else . end' <<<"${cur:-{\}}"; }
  scope="${LANE_SCOPE-$(lane_was scope)}"
  scope="$(printf '%s' "$scope" | tr '\t\r\n' '   ' | tr -d '\000-\037\177' | head -c 500)"
  files="${LANE_FILES-$(lane_was files)}"
  files="$(printf '%s' "$files" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' | grep -v '^$' | head -50 | paste -sd, -)"
  local box="$LANE_BOX" out
  [[ -n "$cur" ]] && box="$(lane_was agent_box)"
  if ! out="$(spl_lane_hub --fleet "$LANE_FLEET" --agent "$LANE_AGENT" --box "$box" \
    --repo "${LANE_REPO-$(lane_was repo)}" --branch "${LANE_BRANCH-$(lane_was branch)}" \
    --scope "$scope" --files "$files" --topic "${LANE_TOPIC-$(lane_was topic)}" --state "$state" 2>&1)"; then
    do_log "WARN lane $LANE_AGENT@$box not written ($state): $(tail -1 <<<"$out")"
    return 2
  fi
  do_log "OK lane $LANE_AGENT@$box $state in fleet $LANE_FLEET"
}

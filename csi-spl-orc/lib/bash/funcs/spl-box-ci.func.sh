#!/bin/bash
#------------------------------------------------------------------------------
# CI busy (owner HUM-10, t1 f67e3656 msg 565d9bbb: "fewer agents on satellite
# while CI runs"). The self-hosted GitHub runners share a box's cores with the
# agents: on 2026-10-11 sat's load5 ran 75..335 % of its 16 cores over 16 wf
# 10 runs, and the e2e shards took 23..36 min against their limits. So a box
# with a runner job active takes FEWER new lanes:
#   - the box knows: spl_box_ci_jobs counts its active runner jobs (one
#     Runner.Worker process per job; the idle Runner.Listener is not one)
#     plus the jobs WAITING for its cores: the runner CPU budget
#     (do_apply_gh_runner_cpu_budget) gives CI only what the agents leave and
#     parks the runners it cannot feed; while it has parked runners here and
#     its last tick (CPU_BUDGET_STATE_DIR/gate, under gate_max_age_s old) saw
#     gate runs waiting, min(parked, waiting) count too. Who yields when: a
#     running agent never (the budget squeezes the runners instead); a NEW
#     agent yields while CI runs or waits here; a parked runner comes back as
#     the agents' load falls (the budget's own hysteresis);
#   - it tells the fleet: spl_lane_box_report puts ci=<N> into its BOX-0 row
#     scope (rewritten at once when N changes, else every LANE_BOX_ROW_S);
#   - do_spl_box_pick reads it (spl_box_ci_from_rows; its own box live) and
#     gives a CI-busy box the lower band (low_pct / high_pct, each at most the
#     box's own) and the agent cap max_agents: at or over the cap the box is
#     not picked at all, so the lane goes to another box or holds.
# Running agents are never stopped, and a spawn with its own id (the hourly
# rotation, a restore) never asks the pick: only new lanes are steered.
# Settings (cnf env.box.ci_busy, env BOX_CI_<KEY> overrides, these defaults
# when neither reads): max_agents 12, low_pct 25, high_pct 50, max_age_s 900
# (a BOX-0 row older than that tells nothing about CI: its cron stopped);
# env BOX_CI_GATE_MAX_AGE_S, default 600: an older budget gate file is stale.
#------------------------------------------------------------------------------

# spl_box_ci_jobs: the runner jobs running or waiting on THIS box, one
# number. Seams (tests): LANE_CI_CMD prints the whole number instead;
# LANE_CI_PS_CMD replaces `ps -eo comm=`.
spl_box_ci_jobs() {
  local n st="${CPU_BUDGET_STATE_DIR:-/var/tmp/gh-runner-cpu-budget}" at="" wait="" parked
  if [[ -n "${LANE_CI_CMD:-}" ]]; then
    n="$($LANE_CI_CMD 2>/dev/null)"; [[ "$n" =~ ^[0-9]+$ ]] || n=0; echo "$n"; return 0
  fi
  n="$(${LANE_CI_PS_CMD:-ps -eo comm=} 2>/dev/null | grep -cx 'Runner.Worker')"
  [[ "$n" =~ ^[0-9]+$ ]] || n=0
  read -r at wait _ 2>/dev/null <"$st/gate"
  parked="$(grep -c . "$st/parked" 2>/dev/null)"
  if [[ "$at" =~ ^[0-9]+$ && "$wait" =~ ^[0-9]+$ && "$parked" =~ ^[0-9]+$ ]] &&
    (( $(date +%s) - at < ${BOX_CI_GATE_MAX_AGE_S:-600} )); then
    n=$(( n + (wait < parked ? wait : parked) ))
  fi
  echo "$n"
}

# spl_box_ci_cnf [CNF]: prints the settings as one JSON object
# {max_agents, low, high, max_age_s}.
spl_box_ci_cnf() {
  local cnf="${1:-}" k v ev out='{}'
  local -A def=([max_agents]=12 [low_pct]=25 [high_pct]=50 [max_age_s]=900)
  for k in "${!def[@]}"; do
    ev="BOX_CI_${k^^}"
    v="${!ev:-}"
    [[ -z "$v" && -r "$cnf" ]] && command -v yq >/dev/null && v="$(yq ".env.box.ci_busy.$k // \"\"" "$cnf" 2>/dev/null)"
    [[ "$v" =~ ^[0-9]+$ ]] || v="${def[$k]}"
    out="$(jq -c --arg k "${k%_pct}" --argjson v "$v" '.[$k] = $v' <<<"$out")"
  done
  echo "$out"
}

# spl_box_ci_from_rows LANES_JSON ROW_ID MAX_AGE_S [HERE HERE_JOBS]: the CI
# jobs per box as {"<box>": N}, from each box's freshest BOX-0 row (agent
# ROW_ID, live, younger than MAX_AGE_S) scope field ci=<N>. HERE_JOBS, when
# given, is this box's own live count and wins over its row.
spl_box_ci_from_rows() {
  jq -c --arg id "$2" --argjson max "$3" --arg here "${4:-}" --arg hj "${5:-}" '
    [(.lanes // [])[] | select(.agent_id == $id and .state == "live" and (.age_s // -1) >= 0 and .age_s < $max)]
    | group_by(.agent_box) | map(min_by(.age_s))
    | map({key: .agent_box, value: ((.scope // "") | [capture("(^| )ci=(?<n>[0-9]+)")][0].n // "0" | tonumber)})
    | from_entries
    | if $here != "" and ($hj | test("^[0-9]+$")) then .[$here] = ($hj | tonumber) else . end' <<<"$1" 2>/dev/null || echo '{}'
}

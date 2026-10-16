#!/bin/bash
#------------------------------------------------------------------------------
# @description What Mistral Vibe (m-) lanes pay for tool output and error
# @description loops (SPL-2217, item 4 of the "Grok burns 3-4x" hypotheses of
# @description t1 bd5579e7): per lane, completions and their input / cached /
# @description output tokens, failed tool calls, error loops (the same failing
# @description tool with the same last error line 3+ times) and the tokens
# @description their results cost by riding along in every later completion.
# @description VIBE_LOOP_CAP=<chars> replays the same sessions with every bash
# @description result capped (the spool-output-cap hook, spool-install Y15).
# @description Read only; the journals are read as the agent user (sudo -n -u).
# @description Script: features/spawn-agents/scripts/vibe-loop-cost.py.
# @param VIBE_LOOP_SINCE (optional) - sessions started at or after (default 1 day ago)
# @param VIBE_LOOP_CAP (optional) - also count what a bash cap of N chars removes
# @param VIBE_LOOP_HOMES (optional, tests) - space-separated homes, read as the current user
# @example ./run -a do_spl_vibe_loop_cost
# @example VIBE_LOOP_SINCE=2026-10-15T18 VIBE_LOOP_CAP=4000 ./run -a do_spl_vibe_loop_cost
#------------------------------------------------------------------------------
do_spl_vibe_loop_cost() {
  local since="${VIBE_LOOP_SINCE:-$(date -u -d '1 day ago' +%Y-%m-%dT%H:%M)}"
  local py="$PROJ_PATH/src/bash/features/spawn-agents/scripts/vibe-loop-cost.py" u h
  local -a args=(--since "$since")
  [[ -n "${VIBE_LOOP_CAP:-}" ]] && args+=(--cap "$VIBE_LOOP_CAP")
  declare -F spl_cost_agent_users >/dev/null || source "$(dirname "${BASH_SOURCE[0]}")/spl-cost-tokens-read.func.sh"
  if [[ -n "${VIBE_LOOP_HOMES:-}" ]]; then
    for h in $VIBE_LOOP_HOMES; do python3 "$py" "${args[@]}" --root "$h/.vibe/logs/session/unified"; done
    return
  fi
  for u in $(spl_cost_agent_users "${SPOOL_ROOT:-/var/spool-hub}"); do
    h="$(getent passwd "$u" | cut -d: -f6)"
    [[ -n "$h" ]] || continue
    do_log "INFO vibe loop cost: $u ($h/.vibe), since $since"
    spl_cost_as "$u" python3 - "${args[@]}" --root "$h/.vibe/logs/session/unified" <"$py"
  done
}

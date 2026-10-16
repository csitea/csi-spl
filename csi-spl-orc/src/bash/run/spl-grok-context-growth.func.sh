#!/bin/bash
#------------------------------------------------------------------------------
# @description Read-only (SPL-2215, grok token burn 2/6): how the context a
# @description model call reads grows over a lane session, grok lanes vs
# @description claude lanes. Prints a markdown table call number -> median
# @description context per vendor, a per-vendor summary (input per session,
# @description growth per call, sessions compacted), and what a grok
# @description auto-compact cap at each of GROWTH_CAPS would have cost on the
# @description same sessions (the row at grok's own 204800 is the model's
# @description control: it must match the measured total within a few %).
# @description The cap itself is cnf env.box.grok_cli, written by
# @description spool-harness.sh. Numbers and lane ids only, never content.
# @description The parser is spl-grok-context-growth.py beside this file.
# @param GROWTH_DAYS (optional) - sessions touched in the last N days, default 7
# @param GROWTH_CAPS (optional) - comma list of caps in tokens, default 80000,100000,128000,150000,204800
# @param GROWTH_USERS (optional) - users whose ~/.grok and ~/.claude are read, default the agent user (box.env)
# @param GROWTH_HOMES (optional) - homes read as the current user instead (tests)
# @example ./run -a do_spl_grok_context_growth
# @example GROWTH_DAYS=1 ./run -a do_spl_grok_context_growth
#------------------------------------------------------------------------------
do_spl_grok_context_growth() {
  do_require_bin python3 || return 1
  local py feat days="${GROWTH_DAYS:-7}" caps="${GROWTH_CAPS:-80000,100000,128000,150000,204800}" since u h
  py="$(dirname "${BASH_SOURCE[0]}")/spl-grok-context-growth.py"
  feat="$(cd "$(dirname "${BASH_SOURCE[0]}")/../features/spawn-agents" && pwd)"
  [[ "$days" =~ ^[1-9][0-9]*$ ]] || { do_log "FATAL GROWTH_DAYS must be a positive integer (got '$days')"; return 2; }
  [[ "$caps" =~ ^[0-9]+(,[0-9]+)*$ ]] || { do_log "FATAL GROWTH_CAPS must be a comma list of token counts (got '$caps')"; return 2; }
  since=$(( EPOCHSECONDS - days * 86400 ))
  if [[ -n "${GROWTH_HOMES:-}" ]]; then
    # shellcheck disable=SC2086  # a space-separated list of homes
    python3 "$py" scan "$since" $GROWTH_HOMES
  else
    declare -F spool_env_resolve >/dev/null || source "$feat/lib/spool-env.inc.sh"
    SPOOL_ENV_NO_BINS=1 spool_env_resolve
    for u in ${GROWTH_USERS:-${SPOOL_AGENT_USER:-}}; do
      h="$(getent passwd "$u" | cut -d: -f6)"
      [[ -n "$h" ]] || { do_log "FATAL no passwd entry for '$u'"; return 2; }
      if [[ "$u" == "$(id -un)" ]]; then python3 "$py" scan "$since" "$h"
      else sudo -n -u "$u" python3 "$py" scan "$since" "$h" ||
        do_log "WARN cannot read $u's sessions (sudo -n -u $u refused): left out"; fi
    done
  fi | python3 "$py" report "$caps"
}

#!/bin/bash

#------------------------------------------------------------------------------
# @description READ-ONLY: print the models each agent CLI on this box offers,
#   read live (spec 184 row A1, contract 7.1.6; owner Q3 "liv"). One block per
#   vendor: "<vendor> cli=<version>" then one model per line, or
#   "<vendor> no list source (exit 4)". Sources: claude's --help aliases, grok's
#   own models cache, vibe's [[models]] names and aliases; agy, qwen and codex
#   have none until row M0. A dry print by hand: no paid call, no hub report,
#   nothing written. Library: spawn-agents/lib/agent-models.inc.sh.
# @param AGENT_MODELS_VENDOR (optional) - claude, grok, mistral, agy, qwen or
#   codex; default all six. With one vendor the action exits with its code
#   (0 a list, 4 no source, 2 unknown vendor)
# @param SPOOL_AGENT_HOME (optional) - the agent user's home, default the
#   home of SPOOL_AGENT_USER, else $HOME
# @example ./run -a do_spl_agent_models_list
# @example AGENT_MODELS_VENDOR=grok ./run -a do_spl_agent_models_list
#------------------------------------------------------------------------------
do_spl_agent_models_list() {
  local v vendors="${AGENT_MODELS_VENDOR:-claude grok mistral agy qwen codex}" out err rc last=0
  # shellcheck source=/dev/null
  . "${PROJ_PATH:-${APP_PATH:-}/csi-spl-orc}/src/bash/features/spawn-agents/lib/agent-models.inc.sh" || return 1
  err="$(mktemp)" || return 1
  for v in $vendors; do
    out="$(spool_agent_models "$v" 2>"$err")"; rc=$?
    case "$rc" in
      0) echo "$v $(grep -m1 '^cli=' "$err")"; printf '%s\n' "$out" | sed 's/^/  /' ;;
      4) echo "$v no list source (exit 4)" ;;
      *) echo "$v unknown vendor (exit $rc)" ;;
    esac
    last="$rc"
  done
  rm -f "$err"
  [[ -n "${AGENT_MODELS_VENDOR:-}" ]] && return "$last"
  return 0
}

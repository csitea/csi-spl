#!/usr/bin/env bash

#------------------------------------------------------------------------------
# @description The agent harness parity check (specs/048-agent-harness-parity):
#   the spawn-agents manifest harness-parity.tsv is complete and true, and all
#   four kinds (claude, grok, agy, qwen) have their adapter, id prefix,
#   spool-agent branch, installer branch, MCP registration, trust store and
#   slash command. The fifth, mistral (specs/110-mistral-vendor), has its slash
#   command; its adapter and restore are planned rows until they land. With HARNESS_REF_DIR set to the frozen box engine's
#   spawn-agents dir it also fails on any reference file that has no row -
#   the drift check; without it that part is skipped (the reference is private).
# @param HARNESS_REF_DIR (optional) - the frozen reference feature dir
# @example ./run -a do_check_harness_parity
# @example HARNESS_REF_DIR=<reference>/src/bash/features/spawn-agents ./run -a do_check_harness_parity
#------------------------------------------------------------------------------
do_check_harness_parity() {
  local t="$PROJ_PATH/src/bash/features/spawn-agents/tests/test-harness-parity.sh"
  [[ -r "$t" ]] || { do_log "FATAL missing $t"; return 1; }
  if [[ -n "${HARNESS_REF_DIR:-}" && ! -d "$HARNESS_REF_DIR" ]]; then
    do_log "FATAL HARNESS_REF_DIR is not a directory: $HARNESS_REF_DIR"; return 1
  fi
  if HARNESS_REF_DIR="${HARNESS_REF_DIR:-}" bash "$t"; then
    do_log "OK the agent harness is whole for claude, grok, agy and qwen, and mistral as built${HARNESS_REF_DIR:+ (every reference file accounted for)}"
  else
    do_log "FAIL the agent harness parity check is red (see above)"; return 1
  fi
}

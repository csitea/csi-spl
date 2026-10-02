#!/bin/bash
#------------------------------------------------------------------------------
# spl_desk_box_default: this machine's desk box id (specs/058).
#
# The hub keeps ONE live socket per (tenant, box id): the last hello wins and
# the other is closed 4409 (superseded). Two machines of one fleet that both
# seat `box-desk` therefore evict each other, flip the roster and split the
# box's queue. Each machine answers from its own box id instead, read in this
# order:
#   1. SPOOL_DESK_BOX in the environment
#   2. SPOOL_DESK_BOX in the box config, $SPOOL_BOX_ENV (default
#      /var/spool-hub/box.env; written by spawn-agents/scripts/box-config.sh)
#   3. box-desk - the one-machine default, so a box with no config is unchanged
# Every DESK_BOX / AGENT_BOX default in the run actions and the desk scripts
# reads it, and an explicit DESK_BOX still wins over it.
# Under SPOOL_TEST=1 (the test harnesses, CLE-77923) the live default file is
# never read: a test sees only the SPOOL_BOX_ENV it names, so the box it runs
# on cannot change its verdict. SPOOL_LIVE_ROOT stands in for the live root in
# the guard's own test.
# Standalone scripts source this file by path: it needs nothing else.
#------------------------------------------------------------------------------
spl_desk_box_default() {
  local v="${SPOOL_DESK_BOX:-}" f="${SPOOL_BOX_ENV:-${SPOOL_LIVE_ROOT:-/var/spool-hub}/box.env}" k val
  [[ "${SPOOL_TEST:-}" == 1 && -z "${SPOOL_BOX_ENV:-}" ]] && f=""
  if [[ -z "$v" && -r "$f" ]]; then
    while IFS='=' read -r k val || [[ -n "$k" ]]; do
      [[ "$k" == SPOOL_DESK_BOX ]] || continue
      val="${val%$'\r'}"; val="${val#\"}"; val="${val%\"}"; val="${val#\'}"; val="${val%\'}"
      v="$val"
    done <"$f"
  fi
  printf '%s' "${v:-box-desk}"
}

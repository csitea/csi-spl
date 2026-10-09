#!/bin/bash
#------------------------------------------------------------------------------
# The agent ids of the non-AI desks, in ONE place (specs/061 follow-up).
#
#   SPL_RSP_AGENT  the responder (do_spl_responder_run / _sweep), seated on
#                  every box-rsp / sat-rsp desk; it was RSP-01
#   SPL_OPS_AGENT  the CI ops desk (spl-ops-alarm-cron.sh, the weekly full
#                  scan, do_spl_deploy_failure_poll) on box-ci; it was OPS-01
#
# Both legacy ids are refused by spool-env since the spec 061 cutoff
# (2026-10-03T20:59:59Z), which failed every responder and desk-box tick.
# The new ids were allocated by next-agent-id.sh and are recorded in
# <spool root>/agent-id-aliases.tsv (RSP-01 -> c-684, OPS-01 -> c-685).
# Kind letter c-: neither desk runs an AI CLI (bash + python only), and c-
# is the grammar's default kind. do_spl_desk_agent_rename moves a seated
# desk from the old id to these.
#
# A desk agent has no tmux window by design, so the dead-agent reaper keeps
# these ids (agent-id-reap.sh reads SPL_DESK_AGENT_IDS).
# DESK_AGENT / --agent still override them per call.
# Standalone scripts source this file by path: it needs nothing else.
#------------------------------------------------------------------------------
SPL_RSP_AGENT="c-684"
SPL_OPS_AGENT="c-685"
# shellcheck disable=SC2034  # read by the scripts that source this file
SPL_DESK_AGENT_IDS="$SPL_RSP_AGENT $SPL_OPS_AGENT"

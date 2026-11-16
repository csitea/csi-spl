#!/usr/bin/env bash
# S1 (SPL-5695, spec 060 add-on claude-account-failover.md section 4.4): a
# fresh login-mode line "backup" makes a claude spawn (and so a rotation,
# which spawns through the same core) start with CLAUDE_CONFIG_DIR=<second
# folder>; "own", a stale line or no line -> none; a caller's own
# SPAWN_CLAUDE_CONFIG_DIR wins; a grok spawn never gets it.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
export SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool
WD="$T_TMP/plain"; mkdir -p "$WD"
echo brief > "$T_TMP/brief.md"
export LOGIN_STATE_DIR="$T_TMP/lc"; mkdir -p "$LOGIN_STATE_DIR"
mode() { printf '%s %s acct-11111111 acct-22222222 91 1893486400 40 %s own at 91%%\n' "${2:-$(date +%s)}" "$1" "$T_TMP/agent/.claude-2" > "$LOGIN_STATE_DIR/login-mode"; }
launch() {  # KIND ID [VAR=value...]
  local k="$1" id="$2"; shift 2
  rm -rf "$T_TMP/plan"; mkdir -p "$T_TMP/plan"
  env SPAWN_PLAN_DIR="$T_TMP/plan" "$@" bash "$T_SCRIPTS/spawn-$k.sh" "$id" "$WD" "$T_TMP/brief.md" "do the thing" >/dev/null 2>&1
  cat "$T_TMP/plan/launch.cmd"
}

mode backup
has "S1: backup -> the claude seat starts under the second folder" "CLAUDE_CONFIG_DIR='$T_TMP/agent/.claude-2'" "$(launch claude c-771)"
has "S1: a caller's own folder wins" "CLAUDE_CONFIG_DIR='/x/own'" "$(launch claude c-772 SPAWN_CLAUDE_CONFIG_DIR=/x/own)"
hasnt "S1: ... and the second folder is not added" "$T_TMP/agent/.claude-2" "$(launch claude c-772 SPAWN_CLAUDE_CONFIG_DIR=/x/own)"
hasnt "S1: a grok spawn never gets it" "CLAUDE_CONFIG_DIR" "$(launch grok g-773)"
mode own
hasnt "S1: own -> no CLAUDE_CONFIG_DIR" "CLAUDE_CONFIG_DIR" "$(launch claude c-774)"
mode backup "$(( $(date +%s) - 600 ))"
hasnt "S1: a stale backup line (600 s) -> none" "CLAUDE_CONFIG_DIR" "$(launch claude c-775)"
rm -f "$LOGIN_STATE_DIR/login-mode"
hasnt "S1: no line -> none" "CLAUDE_CONFIG_DIR" "$(launch claude c-776)"
t_done

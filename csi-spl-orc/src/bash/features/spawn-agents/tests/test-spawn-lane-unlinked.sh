#!/usr/bin/env bash
# A spawn whose lane has no discussion (topic) or no issue says so on the
# spawner's stderr (SPL-4799, spec 153 3.21): the hub refuses that lane-map row
# and the put runs in the background, so without this the lane is missing from
# `lane-map --check` unseen (R7 c-198 W2). Role seats and role-rotation rows
# store `unknown` and are not named. Dry-run spawns: the WARN is printed there too.
set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib.inc.sh"
t_sandbox
export SPAWN_DRY_RUN=1 SPOOL_BIN=/opt/x/spool
WD="$T_TMP/plain"; mkdir -p "$WD"
U=0c2d08a2-b1c1-4bb7-983d-3237203a77ec
printf '# Brief: linked\n\nReport on task `%s`.\n\nIssue: SPL-1\n' "$U" >"$T_TMP/brief-both.md"
printf '# Brief: no issue\n\nReport on task `%s`.\n' "$U" >"$T_TMP/brief-topic.md"
printf '# Brief: no topic\n\nIssue: SPL-1\n' >"$T_TMP/brief-issue.md"
printf '# Brief: neither\nbody\n' >"$T_TMP/brief-none.md"

# warn <id> <brief> [env...]: the LANE ROW REFUSED line a dry-run spawn prints
warn() {
  local id="$1" brief="$2"; shift 2
  env "$@" bash "$T_SCRIPTS/spawn-claude.sh" "$id" "$WD" "$brief" "do it" 2>&1 | grep 'LANE ROW REFUSED'
}
eq "topic and issue -> no warning" "" "$(warn c-871 "$T_TMP/brief-both.md")"
check "no issue -> refused, names the issue" bash -c '[[ "$1" == *"c-872 has no issue:"* ]]' _ "$(warn c-872 "$T_TMP/brief-topic.md")"
check "no topic -> refused, names the discussion" bash -c '[[ "$1" == *"c-873 has no discussion (topic):"* ]]' _ "$(warn c-873 "$T_TMP/brief-issue.md")"
check "neither -> refused, names both" bash -c '[[ "$1" == *"no discussion (topic) and no issue"* ]]' _ "$(warn c-874 "$T_TMP/brief-none.md")"
eq "SPAWN_LANE_TOPIC + SPAWN_ISSUE name them -> no warning" "" "$(warn c-875 "$T_TMP/brief-none.md" SPAWN_LANE_TOPIC="$U" SPAWN_ISSUE=SPL-2)"
eq "a role seat (c-002) is no lane -> no warning" "" "$(warn c-002 "$T_TMP/brief-none.md")"
eq "a role-rotation scope is no lane -> no warning" "" "$(warn c-876 "$T_TMP/brief-none.md" SPAWN_LANE_SCOPE='role c-462 (rotation 20261105T1739Z)')"
check "a scope that merely starts with 'role ' is a lane -> refused" bash -c '[[ -n "$1" ]]' _ "$(warn c-877 "$T_TMP/brief-none.md" SPAWN_LANE_SCOPE='role model review')"
t_done

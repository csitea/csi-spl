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
# A relay hash from the ask (a v5 uuid: dispatch-refactor-r27) must not beat the
# discussion the brief names: the hub refuses a hash of a task that is no topic,
# so the seat got no row (SPL-5144, n=2 on 2026-11-08).
H=0ebd228a-f4c8-59cf-8d41-f684aba97be8
D=b4b264a7-95e9-40aa-a863-529c8637c181
printf '# Brief: review\n\nIssue: SPL-1\nTopic: %s (t1)\n' "$D" >"$T_TMP/brief-disc.md"
printf '# Brief: review\n\nIssue: SPL-1\n' >"$T_TMP/brief-nodisc.md"
# sent <id> <brief> [env...]: the --topic of the lane put a dry-run spawn plans
sent() {
  local id="$1" brief="$2"; shift 2
  env "$@" bash "$T_SCRIPTS/spawn-claude.sh" "$id" "$WD" "$brief" "do it" 2>&1 |
    sed -nE "s/.*lane-map\.sh put .* --topic '([^']*)'.*/\1/p" | sed -n 1p
}
eq "a relay hash from the ask yields to the brief's discussion" "$D" "$(sent c-878 "$T_TMP/brief-disc.md" SPAWN_LANE_TOPIC="$H")"
eq "...also when it came as LANE_ISSUE_TOPIC" "$D" "$(sent c-879 "$T_TMP/brief-disc.md" LANE_ISSUE_TOPIC="$H")"
eq "control: with no discussion in the brief the hash is still sent (the hub may resolve it)" "$H" "$(sent c-880 "$T_TMP/brief-nodisc.md" SPAWN_LANE_TOPIC="$H")"
eq "control: a topic uuid from the ask wins over the brief's" "$U" "$(sent c-881 "$T_TMP/brief-disc.md" SPAWN_LANE_TOPIC="$U")"
# A v5 from the ask can be a real topic: a dispatch-<8hex> the brief merely
# mentions must not beat it (SPL-5144, R7 c-437 W1); only a named discussion does.
printf '# Brief: review\n\nIssue: SPL-1\nSee the task dispatch-1234abcd for the history.\n' >"$T_TMP/brief-stray.md"
printf '# Brief: review\n\nIssue: SPL-1\nDiscussion: %s\nSee the task dispatch-1234abcd.\n' "$D" >"$T_TMP/brief-stray-disc.md"
eq "a stray dispatch-<8hex> in the brief does not beat a v5 from the ask" "$H" "$(sent c-882 "$T_TMP/brief-stray.md" SPAWN_LANE_TOPIC="$H")"
eq "...nor as LANE_ISSUE_TOPIC" "$H" "$(sent c-883 "$T_TMP/brief-stray.md" LANE_ISSUE_TOPIC="$H")"
eq "control: a named Discussion: still beats the v5, stray dispatch or not" "$D" "$(sent c-884 "$T_TMP/brief-stray-disc.md" SPAWN_LANE_TOPIC="$H")"
eq "control: with no topic in the ask the dispatch-<8hex> read still works" "1234abcd" "$(sent c-885 "$T_TMP/brief-stray.md")"
t_done

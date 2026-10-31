#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: spl_spawn_share_lanes (do_spl_spawn_share's input) keeps only the
#          lanes the lane map itself calls recent (SPL-2836, bug round 3 row
#          01): the share was computed over hub rows nobody refreshed for days
#          and over leftover local worktrees. The lane map is a stub
#          (SPAWN_SHARE_LANES_CMD).
#   1. a live row 600 s old stays, one 330000 s old goes (red before the fix)
#   2. the hub answered: a local row with no age goes (red before the fix)
#   3. the hub did not answer (or the input has no .hub): a row with no age
#      stays, as the old stubs of spl-spawn-queue / spl-spawn-fill build them
#   4. a live role seat stays at any age; a done row never counts
#   5. LANE_RECENT_S moves the cut; an age of exactly the cut goes
#   Bands by phase (spec 166 row B2, SPL-4499), spl_spawn_share_jq at
#   RHYTHM_NOW, 10 lanes: refactor 3, bug 2, feature 5:
#   6. day 12:00Z: bands refactor 10-20, bug 15-20, phase day; night 22:00Z:
#      refactor 40-60, bug 30-40, phase night (red on the one band set)
#   7. the 24 h share: the samples of the last 24 h only, against the owner's
#      20-30% bands; no samples -> no data, never capped
#   8. capped only at night and only refactor or bug at their 24 h top
#   9. spl_spawn_share_sample: a sample is written, a second within
#      SPAWN_SHARE_SAMPLE_MIN is not, samples over 24 h old are dropped
#  10. the line and the markdown report print the phase, the 24 h share and
#      a capped class
#  11. SPAWN_SHARE_BANDS: one band set for every phase
#  12. a phase that cannot be read: phase unknown, the day bands, a WARN, and
#      the report says so (never a plain day)
#  13. a sample's trim drops lines whose time is not a number
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v jq >/dev/null || { echo "FAIL: jq is required"; exit 1; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export SPOOL_TEST=1

# ids LANES_JSON [VAR=value...]: the ids spl_spawn_share_lanes keeps.
ids() {
  local json="$1"; shift
  printf '%s\n' "$json" >"$T/lanes.json"
  env "$@" SPAWN_SHARE_LANES_CMD="cat $T/lanes.json" bash -c '
    source "$1/src/bash/run/spl-spawn-share.func.sh"
    spl_spawn_share_lanes' _ "$PROJ_ROOT" | jq -r '[.[] | .agent_id + "@" + .agent_box] | join(",")'
}
check() {  # NAME WANT GOT
  if [[ "$3" == "$2" ]]; then pass "$1"; else fail "$1: want '$2', got '$3'"; fi
}

# 1. a stale hub row goes
got="$(ids '{"lanes":[{"agent_id":"c-101","agent_box":"sat","state":"live","age_s":600},{"agent_id":"a-313","agent_box":"sat","state":"live","age_s":330000}]}')"
check "1 a 330000 s old live row is left out" "c-101@sat" "$got"

# 2. the hub answered: a local leftover with no age goes
got="$(ids '{"hub":"ok","lanes":[{"agent_id":"c-101","agent_box":"sat","state":"live","age_s":600,"src":"hub"},{"agent_id":"c-102","agent_box":"sat","state":"live","age_s":-1,"src":"local"}]}')"
check "2 hub ok: a local row with no age is left out" "c-101@sat" "$got"

# 3. the hub did not answer, or no .hub: rows with no age are the whole map
got="$(ids '{"hub":"unreachable","lanes":[{"agent_id":"c-102","agent_box":"sat","state":"live","age_s":-1,"src":"local"}]}')"
check "3 hub unreachable: a row with no age stays" "c-102@sat" "$got"
got="$(ids '{"lanes":[{"agent_id":"c-201","agent_box":"box2","state":"live"},{"agent_id":"c-202","agent_box":"sat","state":"live"}]}')"
check "3 no .hub, no age_s (the old stubs): both rows stay" "c-201@box2,c-202@sat" "$got"

# 4. role seats stay at any age; done rows never count
got="$(ids '{"hub":"ok","lanes":[{"agent_id":"c-001","agent_box":"sat","state":"live","age_s":330000},{"agent_id":"g-002","agent_box":"box2","state":"live","age_s":-1},{"agent_id":"c-103","agent_box":"sat","state":"done","age_s":60},{"agent_id":"c-004","agent_box":"sat","state":"live","age_s":330000}]}')"
check "4 live role seats stay, a done row and a stale c-004 go" "c-001@sat,g-002@box2" "$got"

# 5. LANE_RECENT_S moves the cut
lanes='{"hub":"ok","lanes":[{"agent_id":"c-101","agent_box":"sat","state":"live","age_s":0},{"agent_id":"c-102","agent_box":"sat","state":"live","age_s":7199},{"agent_id":"c-103","agent_box":"sat","state":"live","age_s":7200}]}'
check "5 default cut 7200 s: 0 and 7199 stay, 7200 goes" "c-101@sat,c-102@sat" "$(ids "$lanes")"
check "5 LANE_RECENT_S=100: only the 0 s row stays" "c-101@sat" "$(ids "$lanes" LANE_RECENT_S=100)"

# 6-11. bands by phase -----------------------------------------------------------
NIGHT=2026-01-15T22:00Z DAY=2026-01-15T12:00Z
mkdir -p "$T/fx" "$T/asks"
jq -n -c '[range(10) | {agent_id: "c-\(100 + .)", agent_box: "sat"}]' >"$T/fx/lanes.json"
jq -c '[.[] | .agent_id + "@sat"] | to_entries
  | map({key: .value, value: (if .key < 3 then "refactor" elif .key < 5 then "bug" else "feature" end)}) | from_entries' "$T/fx/lanes.json" >"$T/fx/briefs.json"
printf '{"asks": []}' >"$T/fx/asks.json"; printf '[]' >"$T/fx/log.json"
# shr NOW CODE [VAR=value...]: CODE run with the share functions at NOW; $SHARE
# is the share of the fixture (and the samples in $T/asks).
shr() {
  local now="$1" code="$2"; shift 2
  env SPOOL_ROOT="$T/spool" SPOOL_ASKS_DIR="$T/asks" APP_PATH="$T" RHYTHM_NOW="$now" FX="$T/fx" "$@" bash -c '
    do_log() { printf "%s\n" "$*" >&2; }
    source "$1/src/bash/features/spawn-agents/lib/spool-asks.inc.sh"
    source "$1/src/bash/run/spl-spawn-share.func.sh"
    d="$(mktemp -d)"; cp "$FX"/*.json "$d/"; SHARE="$(spl_spawn_share_jq "$d")"; rm -rf "$d"
    eval "$2"' _ "$PROJ_ROOT" "$code" 2>"$T/err"
}
bands='[.phase, .by.refactor.lo, .by.refactor.hi, .by.bug.lo, .by.bug.hi, .by.feature.lo] | map(tostring) | join(" ")'
check "6 day: refactor 10-20, bug 15-20, feature 60-" "day 10 20 15 20 60" "$(shr "$DAY" 'jq -r "$B" <<<"$SHARE"' B="$bands")"
check "6 night: refactor 40-60, bug 30-40, feature 0-" "night 40 60 30 40 0" "$(shr "$NIGHT" 'jq -r "$B" <<<"$SHARE"' B="$bands")"
check "6 night verdicts: refactor 30% UNDER, bug 20% UNDER" "UNDER UNDER" "$(shr "$NIGHT" 'jq -r "[.by.refactor.verdict, .by.bug.verdict] | join(\" \")" <<<"$SHARE"')"

h24='[.h24.samples, .h24.by.refactor.pct, .h24.by.bug.pct, .h24.by.refactor.lo, .h24.by.refactor.hi, .h24.by.refactor.verdict] | map(tostring) | join(" ")'
rm -f "$T/asks/share.24h.tsv"
check "7 no samples: no data" "0 null null 20 30 no data" "$(shr "$NIGHT" 'jq -r "$B" <<<"$SHARE"' B="$h24")"
check "7 no samples: never capped" "false false" "$(shr "$NIGHT" 'jq -r "[.by.refactor.capped, .by.bug.capped] | map(tostring) | join(\" \")" <<<"$SHARE"')"
n=$(date -d "$NIGHT" +%s)
printf '%s\tday\t10\t3\t1\t6\n%s\tday\t10\t9\t0\t1\n%s\tnight\t10\t3\t3\t4\n' "$((n - 3600))" "$((n - 90000))" "$((n - 600))" >"$T/asks/share.24h.tsv"
check "7 two samples in 24 h (the 25 h old one left out): refactor 30%, bug 20%" "2 30 20 20 30 ok" "$(shr "$NIGHT" 'jq -r "$B" <<<"$SHARE"' B="$h24")"
check "8 night, 24 h refactor 30% (top 30): refactor capped, bug 20% not, feature never" "true false false" \
  "$(shr "$NIGHT" 'jq -r "[.by.refactor.capped, .by.bug.capped, .by.feature.capped] | map(tostring) | join(\" \")" <<<"$SHARE"')"
check "8 day, the same samples: nothing capped" "false false" "$(shr "$DAY" 'jq -r "[.by.refactor.capped, .by.bug.capped] | map(tostring) | join(\" \")" <<<"$SHARE"')"

rm -f "$T/asks/share.24h.tsv"
printf '%s\tday\t10\t1\t1\t8\n' "$((n - 90000))" >"$T/asks/share.24h.tsv"
shr "$NIGHT" 'printf "%s" "$SHARE" >"$T/s.json"; spl_spawn_share_sample "$T/s.json"' T="$T"
check "9 a sample is written, the 25 h old one dropped" "$n night 10 3 2 5" "$(tr '\t' ' ' <"$T/asks/share.24h.tsv")"
shr "$(date -u -d "@$((n + 300))" +%FT%TZ)" 'spl_spawn_share_sample "$T/s.json"' T="$T"
check "9 a second sample 5 min later is not written (SPAWN_SHARE_SAMPLE_MIN 10)" "1" "$(wc -l <"$T/asks/share.24h.tsv")"
shr "$(date -u -d "@$((n + 600))" +%FT%TZ)" 'spl_spawn_share_sample "$T/s.json"' T="$T"
check "9 one 10 min later is" "2" "$(wc -l <"$T/asks/share.24h.tsv")"

line="$(shr "$NIGHT" 'spl_spawn_share_line "$SHARE"')"
[[ "$line" == "share of 10 known live lanes (0 unknown, left out): refactor 3 30% (band 40-60%: UNDER, 24 h top reached), "* &&
   "$line" == *"; phase night; last 24 h (1 sample(s)): refactor 30% (band 20-30%: ok)"* ]] &&
  pass "10 the line: today's start, then the phase and the 24 h share" || fail "10 line: $line"
md="$(shr "$NIGHT" 'spl_spawn_share_md "$SHARE"')"
grep -q "phase \*\*night\*\*" <<<"$md" && grep -qE "^\| refactor \| 3 \| 30% \| 40-60% \| UNDER, 24 h top reached: not preferred tonight \|" <<<"$md" &&
  grep -qE "^\| refactor \| 30% \| 20-30% \| ok \|" <<<"$md" &&
  pass "10 the markdown report: the phase, its bands and the last 24 h table" || fail "10 md: $md"

check "11 SPAWN_SHARE_BANDS: the owner's set at night" "night 20 30 20 30 40" \
  "$(shr "$NIGHT" 'jq -r "$B" <<<"$SHARE"' B="$bands" SPAWN_SHARE_BANDS='{"refactor": [20, 30], "bug": [20, 30], "feature": [40, 100]}')"

check "12 unreadable phase: unknown, the day bands" "unknown 10 20 15 20 60" "$(shr not-a-date 'jq -r "$B" <<<"$SHARE"' B="$bands")"
grep -q "WARN the rhythm phase could not be read: the day bands" "$T/err" && pass "12 unreadable phase: a WARN" || fail "12 WARN: $(cat "$T/err")"
md="$(shr not-a-date 'spl_spawn_share_md "$SHARE"')"
grep -q "phase \*\*unknown\*\* (unread: the day bands)" <<<"$md" && pass "12 the report says unknown (the day bands)" || fail "12 md: $md"

printf 'garbage line\nzzz\tx\n' >>"$T/asks/share.24h.tsv"
shr "$(date -u -d "@$((n + 1200))" +%FT%TZ)" 'spl_spawn_share_sample "$T/s.json"' T="$T"
check "13 the trim drops the lines whose time is not a number" "3 0" \
  "$(wc -l <"$T/asks/share.24h.tsv") $(grep -cvE '^[0-9]+'$'\t' "$T/asks/share.24h.tsv")"

echo "$fails failure(s)"
((fails == 0))

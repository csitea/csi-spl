#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the placer's band pick, supply check and review-seat pick take the
#          hub's lists through files, never argv (SPL-4156). One argument
#          holds at most 128 KiB (MAX_ARG_STRLEN); the live share carried
#          430 bypasses, 171 KB on sat 2026-10-29, and the band pick died on
#          "jq: Argument list too long" every tick: placements fell back to
#          plain queue order. Earlier fixes of the same class: SPL-1854
#          (share inputs), SPL-2428 (group asks).
#   1. band pick, a share over 200 KiB: the bug under its band is picked
#      before the refactor head, "INFO band pick" logged, no jq error (red
#      before the fix); the same pick with a small share (CONTROL)
#   2. supply, a share and a queue list over 200 KiB: ONE blocker for the
#      class under its band (red before the fix); CONTROL: a queued row of
#      that class -> no blocker
#   3. review-seat pick, a bypass log whose GO ids are over 200 KiB: the
#      queued reviewer row is picked (red before the fix)
#   Bands by phase (spec 166 row B2, SPL-4499): the share is computed by the
#   real spl_spawn_share_jq at RHYTHM_NOW, 20 live lanes: refactor 7 (35%),
#   bug 5 (25%), feature 8 (40%); the feature row is the queue's head.
#   4. night: refactor + feature queued -> refactor (red on the one band set:
#      refactor 35% is over 20-30%, feature is taken)
#   5. night: bug + feature queued -> bug
#   6. day: both inputs -> feature (bug 25% is over the day's 15-20%; red on
#      the one band set, where bug 25% is in band and taken)
#   7. night, the last 24 h refactor share at 30% -> feature over refactor;
#      the same for bug (red on the one band set for bug)
#   8. night: an owner-approved bypass feature head is taken as it is, before
#      a refactor under its band (poll Q6 A)
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
BIG=$((200 * 1024))
GO=994f2257-8ad1-4010-88c8-4f0a16230937

# share NBYPASS: a share (refactor 30% ok, bug 10% UNDER, feature 60%) with N
# bypass rows of ~200 bytes each.
share() {
  jq -n -c --argjson n "$1" '{known: 10, unknown: 0, lanes: [],
    by: {refactor: {n: 3, pct: 30, lo: 20, hi: 30, verdict: "ok"}, bug: {n: 1, pct: 10, lo: 20, hi: 30, verdict: "UNDER"},
         feature: {n: 6, pct: 60, lo: 40, hi: 100, verdict: "ok"}},
    bypasses: [range($n) | {msg: "8cb6cc7d", ask: "a\(.)", lane: "c-\(.)@sat", by: "c-001@sat", note: ("x" * 150)}]}'
}
# rows NPAD: a refactor head, a bug at 2, and N queued feature rows of ~1 KB.
rows() {
  jq -n -c --argjson n "$1" '[{ask_id: "r0000000-0", state: "queued", class: "refactor", position: 1},
    {ask_id: "b0000000-0", state: "queued", class: "bug", position: 2}]
    + [range($n) | {ask_id: "f\(.)", state: "queued", class: "feature", position: (. + 3), summary: ("y" * 1000)}]'
}
# run FN ARGS...: FN from the placer, with stubs; stdout to $T/out, stderr to
# $T/err. An ARG "@FILE" is FILE's content, read inside: a big list cannot
# reach the test shell as an argument either.
run() {
  env SPOOL_ROOT="$T/spool" SPOOL_ASKS_DIR="$T/asks" PROJ_PATH="$PROJ_ROOT" SPAWN_SHARE_DISPATCH=c-002@sat RHYTHM_NOW=2026-01-15T12:00Z \
    SPL_SPAWN_REVIEW_SEAT_GO="$GO" BIG_SHARE="$T/share.json" SEND_LOG="$T/send.log" bash -c '
    do_log() { printf "%s\n" "$*"; }
    source "$1/src/bash/features/spawn-agents/lib/spool-asks.inc.sh"
    source "$1/src/bash/run/spl-spawn-share.func.sh"
    source "$1/src/bash/run/spl-spawn-place.func.sh"
    SPOOL_PARTICIPANT_RX="[a-z]-[0-9]{3}"
    spl_spawn_share() { cat "$BIG_SHARE"; }
    spl_spawn_q_send() { printf "%s %s %s %s %s\n" "$@" >>"$SEND_LOG"; }
    spl_spawn_q_review_seat_go() { return 0; }
    shift; args=(); for a in "$@"; do [[ "$a" == @* ]] && a="$(cat "${a#@}")"; args+=("$a"); done
    "${args[@]}"' _ "$PROJ_ROOT" "$@" >"$T/out" 2>"$T/err"
}
mkdir -p "$T/asks" "$T/spool"

# 1. band pick
share 1200 >"$T/share.json"
(( $(stat -c %s "$T/share.json") > BIG )) || fail "1 the generated share is under 200 KiB"
head="$(rows 0 | jq -c '.[0]')"
run spl_spawn_place_band "$head" "$(rows 0)"
if [[ "$(jq -r .ask_id "$T/out" 2>/dev/null)" == b0000000-0 ]] && grep -q "INFO band pick: ask b0000000 (bug at 10%, queue position 2)" "$T/err" &&
   ! grep -q "Argument list too long" "$T/err"; then
  pass "1 band pick, share of $(stat -c %s "$T/share.json") bytes: the bug under its band before the refactor head"
else fail "1 band pick with a big share: out $(head -c 200 "$T/out") | err $(head -c 300 "$T/err")"; fi
share 2 >"$T/share.json"
run spl_spawn_place_band "$head" "$(rows 0)"
[[ "$(jq -r .ask_id "$T/out" 2>/dev/null)" == b0000000-0 ]] && grep -q "INFO band pick: ask b0000000" "$T/err" &&
  pass "1 CONTROL: a small share, the same pick" || fail "1 small share: out $(head -c 200 "$T/out") | err $(head -c 300 "$T/err")"

# 2. supply
share 1200 >"$T/share.json"
big_rows="$(rows 250 | jq -c '[.[] | select(.class != "bug")]')"
(( ${#big_rows} > BIG )) || fail "2 the generated queue list is under 200 KiB"
: >"$T/send.log"
printf '%s' "$big_rows" >"$T/rows.json"
run spl_spawn_place_supply c-001@sat "@$T/rows.json"
if [[ "$(grep -c "spawn-share \*\*SPAWN SHARE: bug share 10% < 20%" "$T/send.log")" == 1 && "$(wc -l <"$T/send.log")" == 1 ]] &&
   ! grep -q "Argument list too long" "$T/err"; then
  pass "2 supply, share and queue list over 200 KiB: ONE blocker for bug, none for refactor in band"
else fail "2 supply with big inputs: sends $(cat "$T/send.log") | err $(head -c 300 "$T/err") | out $(head -c 300 "$T/out")"; fi
: >"$T/send.log"; rm -f "$T/asks"/.share.*
rows 250 >"$T/rows.json"
run spl_spawn_place_supply c-001@sat "@$T/rows.json"
[[ ! -s "$T/send.log" ]] && ! grep -q "Argument list too long" "$T/err" &&
  pass "2 CONTROL: a bug row queued -> no blocker" || fail "2 control: sends $(cat "$T/send.log") | err $(head -c 300 "$T/err")"

# 3. review-seat pick
for i in $(seq 6000); do printf '2026-10-29T00:00:00Z\t%08d-0000-4000-8000-%012d\t%s\tc-001@sat\tseat\n' "$i" "$i" "$GO"; done >"$T/asks/bypass.tsv"
printf '2026-10-29T00:00:00Z\ts0000000-0000-4000-8000-000000000001\t%s\tc-001@sat\tseat\n' "$GO" >>"$T/asks/bypass.tsv"
seat_rows='[{"ask_id":"r0000000-0","state":"queued","class":"refactor","position":1},{"ask_id":"s0000000-0000-4000-8000-000000000001","state":"queued","class":"bug","position":2,"placement":"claude:spl-4156-reviewer"}]'
(( $(cut -f2 "$T/asks/bypass.tsv" | jq -R -s -c 'split("\n")' | wc -c) > BIG )) || fail "3 the generated id list is under 200 KiB"
run spl_spawn_place_seat "$seat_rows"
[[ "$(jq -r .ask_id "$T/out" 2>/dev/null)" == s0000000-0000-4000-8000-000000000001 ]] && ! grep -q "Argument list too long" "$T/err" &&
  pass "3 review-seat pick, a bypass log of 6001 GO rows: the queued reviewer row" ||
  fail "3 seat pick with a big bypass log: out $(head -c 200 "$T/out") | err $(head -c 300 "$T/err")"

# 4-8. bands by phase ------------------------------------------------------------
NIGHT=2026-01-15T22:00Z DAY=2026-01-15T12:00Z
mkdir -p "$T/fx"
jq -n -c '[range(20) | {agent_id: "c-\(100 + .)", agent_box: "sat"}]' >"$T/fx/lanes.json"
jq -c '[.[] | .agent_id + "@sat"] | to_entries
  | map({key: .value, value: (if .key < 7 then "refactor" elif .key < 12 then "bug" else "feature" end)}) | from_entries' "$T/fx/lanes.json" >"$T/fx/briefs.json"
printf '{"asks": []}' >"$T/fx/asks.json"; printf '[]' >"$T/fx/log.json"
# rows2 CLASS [FLAG]: the feature head (position 1) and one CLASS row (position 2).
rows2() {
  jq -n -c --arg c "$1" --arg f "${2:-}" '[{ask_id: "f0000000-0", state: "queued", class: "feature", position: 1, flag: $f},
    {ask_id: "x0000000-0", state: "queued", class: $c, position: 2}]'
}
# pick NOW CLASS [FLAG]: the ask the band pick takes, the share computed at NOW
# from the fixture and the 24 h samples in $T/asks/share.24h.tsv.
pick() {
  local r; r="$(rows2 "$2" "${3:-}")"
  env SPOOL_ROOT="$T/spool" SPOOL_ASKS_DIR="$T/asks" PROJ_PATH="$PROJ_ROOT" APP_PATH="$T" RHYTHM_NOW="$1" FX="$T/fx" bash -c '
    do_log() { printf "%s\n" "$*"; }
    source "$1/src/bash/features/spawn-agents/lib/spool-asks.inc.sh"
    source "$1/src/bash/run/spl-spawn-share.func.sh"
    source "$1/src/bash/run/spl-spawn-place.func.sh"
    spl_spawn_share() { local d; d="$(mktemp -d)"; cp "$FX"/*.json "$d/"; spl_spawn_share_jq "$d"; rm -rf "$d"; }
    spl_spawn_place_seat() { return 0; }
    spl_spawn_place_band "$(jq -c ".[0]" <<<"$2")" "$2" | jq -r .ask_id' _ "$PROJ_ROOT" "$r" 2>"$T/err"
}
# hist R B F: one 24 h sample an hour before the night case, 10 lanes.
hist() {
  printf '%s\tday\t10\t%s\t%s\t%s\n' "$(( $(date -d "$NIGHT" +%s) - 3600 ))" "$1" "$2" "$3" >"$T/asks/share.24h.tsv"
}
rm -f "$T/asks/bypass.tsv" "$T/asks/share.24h.tsv"
got="$(pick "$NIGHT" refactor)"
[[ "$got" == x0000000-0 ]] && pass "4 night, refactor 35% (night band 40-60%): the refactor row before the feature head" ||
  fail "4 night refactor: got '$got' | $(head -c 400 "$T/err")"
got="$(pick "$NIGHT" bug)"
[[ "$got" == x0000000-0 ]] && pass "5 night, bug 25% (night band 30-40%): the bug row before the feature head" ||
  fail "5 night bug: got '$got' | $(head -c 400 "$T/err")"
got="$(pick "$DAY" refactor) $(pick "$DAY" bug)"
[[ "$got" == "f0000000-0 f0000000-0" ]] && pass "6 day, refactor 35% and bug 25% (day bands 10-20%, 15-20%): both inputs take the feature" ||
  fail "6 day: got '$got' (refactor input, bug input) | $(head -c 400 "$T/err")"
hist 3 2 5
got="$(pick "$NIGHT" refactor)"
[[ "$got" == f0000000-0 ]] && grep -q "24 h top reached" "$T/err" &&
  pass "7 night, the last 24 h refactor share at 30%: the feature over the refactor" ||
  fail "7 night refactor capped: got '$got' | $(head -c 400 "$T/err")"
hist 2 3 5
got="$(pick "$NIGHT" bug)"
[[ "$got" == f0000000-0 ]] && pass "7 night, the last 24 h bug share at 30%: the feature over the bug" ||
  fail "7 night bug capped: got '$got' | $(head -c 400 "$T/err")"
hist 2 2 6
got="$(pick "$NIGHT" refactor)"
[[ "$got" == x0000000-0 ]] && pass "7 CONTROL: the last 24 h refactor share at 20%: the night takes the refactor" ||
  fail "7 control: got '$got' | $(head -c 400 "$T/err")"
rm -f "$T/asks/share.24h.tsv"
got="$(pick "$NIGHT" refactor bypass) $(pick "$DAY" refactor bypass)"
[[ "$got" == "f0000000-0 f0000000-0" ]] && pass "8 an owner-approved bypass feature head is placed at night as by day, before a refactor under its band" ||
  fail "8 bypass: got '$got' (night, day) | $(head -c 400 "$T/err")"

echo "$fails failure(s)"
((fails == 0))

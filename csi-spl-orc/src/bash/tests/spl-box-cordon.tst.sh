#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_box_cordon (sat alone panel row 01, SPL-2629) writes,
#          shows and lifts <spool root>/dispatch/cordon/<box>:
#          1. show with no marker; on is a dry run unless DRY_RUN=0;
#          2. on writes until=<epoch> CORDON_MIN ahead, show says CORDONED;
#          3. spl_box_cordon_active lists only the live cordons (an expired
#             or malformed marker is none);
#          4. off lifts it (dry run first); off with nothing is no error;
#          5. bad input FATALs (CORDON_CMD, BOX, CORDON_MIN, DRY_RUN);
#          6. the placer's pinned-row check holds a row pinned to a box
#             whose BOX line says CORDONED (RED CONTROL: the same line
#             without CORDONED is not held).
#          The pick side (a cordoned box is never picked): spl-box-pick.tst.sh 17.
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
C="$T/spool/dispatch/cordon"

cordon() {
  env SPOOL_ROOT="$T/spool" SPOOL_AGENT_ID=c-000 "$@" bash -c '
    set -uo pipefail
    do_log() { echo "$*"; }
    source "'"$PROJ_ROOT"'/src/bash/run/spl-box-cordon.func.sh"
    do_spl_box_cordon'
}
active() { SPOOL_ROOT="$T/spool" bash -c 'source "'"$PROJ_ROOT"'/src/bash/run/spl-box-cordon.func.sh"; spl_box_cordon_active'; }

# 1. nothing cordoned; on without DRY_RUN=0 writes nothing
out="$(cordon)"
[[ "$out" == "box-cordon: no cordon ($C)" ]] && pass "1. show, no marker -> no cordon" || fail "1. show: $out"
out="$(cordon BOX=box-a CORDON_CMD=on)"
[[ ! -e "$C/box-a" ]] && grep -q '^box-cordon: WOULD cordon box-a for 240 min, until ' <<<"$out" &&
  pass "1. on is a dry run by default (WOULD, no file)" || fail "1. dry on: $out"

# 2. on, for real
t0=$(date +%s)
out="$(cordon BOX=box-a CORDON_CMD=on CORDON_MIN=30 DRY_RUN=0)"
u="$(sed -n '1s/^until=\([0-9]*\) .*/\1/p' "$C/box-a" 2>/dev/null)"
[[ -n "$u" ]] && (( u >= t0 + 1800 && u <= $(date +%s) + 1800 )) && grep -q ' by=c-000 min=30$' "$C/box-a" &&
  pass "2. on writes until=<now + 30 min> by=c-000 min=30" || fail "2. on: $out / $(cat "$C/box-a" 2>&1)"
out="$(cordon)"
grep -q "^CORDONED box-a until 20[0-9-]*T[0-9:]*Z (until=$u " <<<"$out" && pass "2. show says CORDONED box-a until <UTC>" || fail "2. show: $out"

# 3. the reader: live only
printf 'until=%s\n' $(( $(date +%s) - 5 )) >"$C/box-b"
printf 'garbage\n' >"$C/box-c"
[[ "$(active)" == "{\"box-a\":$u}" ]] && pass "3. active cordons: box-a only (box-b expired, box-c malformed)" || fail "3. active: $(active)"
out="$(cordon BOX=box-b)"
grep -q '^expired box-b (until=.*): not a cordon$' <<<"$out" && [[ $(wc -l <<<"$out") == 1 ]] &&
  pass "3. show BOX=box-b -> expired, not a cordon" || fail "3. show expired: $out"

# 4. off
out="$(cordon BOX=box-a CORDON_CMD=off)"
[[ -e "$C/box-a" ]] && grep -q '^box-cordon: WOULD lift the cordon on box-a' <<<"$out" && pass "4. off is a dry run by default" || fail "4. dry off: $out"
cordon BOX=box-a CORDON_CMD=off DRY_RUN=0 >/dev/null
[[ ! -e "$C/box-a" && "$(active)" == "{}" ]] && pass "4. off DRY_RUN=0 removes the marker" || fail "4. off: $(ls "$C")"
out="$(cordon BOX=box-a CORDON_CMD=off DRY_RUN=0)"; rc=$?
[[ $rc == 0 && "$out" == *"not cordoned"* ]] && pass "4. off with nothing to lift -> rc 0" || fail "4. off twice: rc=$rc $out"

# 5. bad input
for bad in "CORDON_CMD=drain BOX=box-a" "CORDON_CMD=on" "CORDON_CMD=on BOX=Box_A" "CORDON_CMD=on BOX=box-a CORDON_MIN=0" \
           "CORDON_CMD=on BOX=box-a CORDON_MIN=10081" "CORDON_CMD=on BOX=box-a DRY_RUN=yes"; do
  # shellcheck disable=SC2086 # the case's VAR=value words, split on purpose
  out="$(cordon $bad)"; rc=$?
  [[ $rc != 0 && "$out" == FATAL* ]] && pass "5. $bad -> FATAL" || fail "5. $bad: rc=$rc $out"
done
[[ ! -e "$C/box-a" ]] && pass "5. no bad input wrote a marker" || fail "5. a marker was written"

# 6. the placer's pinned-row check (spl_spawn_place_pin_full)
pin() {
  printf '%s\n' "$1" >"$T/pick.out"
  SPAWN_PLACE_PICK_CMD="cat $T/pick.out" bash -c '
    do_log() { echo "$*"; }
    source "'"$PROJ_ROOT"'/src/bash/run/spl-spawn-place.func.sh"
    spl_spawn_place_pin_full box-a'
}
line='BOX box-a  load5 1  cpus 8  12%  under  band 50..75 (fleet)'
out="$(pin "$line  CORDONED (until 2026-10-20T04:00:00Z)")"; rc=$?
[[ $rc == 0 && "$out" == "box box-a is CORDONED (do_spl_box_cordon)" ]] &&
  pass "6. a row pinned to a CORDONED box is held: $out" || fail "6. pinned cordoned: rc=$rc $out"
out="$(pin "$line")"; rc=$?
[[ $rc == 1 && -z "$out" ]] && pass "6. RED CONTROL the same line without CORDONED is not held" || fail "6. control: rc=$rc $out"

echo "spl-box-cordon: $fails failure(s)"
[ "$fails" -eq 0 ]

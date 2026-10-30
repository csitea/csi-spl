#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_spl_rhythm_phase (spec 166 row B1) prints day or night; night is
# 20:00 to 07:00 Europe/Berlin (CET in winter, CEST in summer).
#   1. the spec's five cases on the real cnf (winter and summer edges)
#   2. red control: a fixed +1 offset fails both July cases
#   3. red control: TZ=CET on a box with no zoneinfo/CET fails 19:00Z winter
#   4. the guard: a cnf zone with no tz database file is refused
#   5. a cnf night_start outside 0..23 is refused (the action; the
#      conf-validator's own case is tests/test_rhythm.py, run here when its
#      python is on hand)
#   6. a RHYTHM_NOW that is not a date is refused; the window may sit inside
#      one day (night_start < night_end)
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
FUNC="$PROJ_ROOT/src/bash/run/spl-rhythm-phase.func.sh"
CASES=(2026-01-15T18:59Z:day 2026-01-15T19:00Z:night 2026-07-15T18:00Z:night 2026-07-15T05:00Z:day 2026-01-15T06:00Z:day)

# phase [VAR=value]... -- NOW [SNIPPET]: the action in a fresh bash; SNIPPET
# (optional) runs after the source, to plant a variant.
phase() {
  local -a vars=()
  while [[ "$1" != -- ]]; do vars+=("$1"); shift; done; shift
  env APP_PATH="$APP_ROOT" PROJ_PATH="$PROJ_ROOT" RHYTHM_NOW="$1" FUNC="$FUNC" SNIPPET="${2:-}" "${vars[@]}" bash -c '
    set -uo pipefail
    do_log() { echo "$*" >&2; }
    source "$FUNC"; eval "$SNIPPET"
    do_spl_rhythm_phase'
}

# wrong_cases [VAR=value]... -- [SNIPPET]: the CASES whose verdict is wrong.
wrong_cases() {
  local c got out=""
  local -a vars=()
  while [[ "$1" != -- ]]; do vars+=("$1"); shift; done; shift
  for c in "${CASES[@]}"; do
    got="$(phase "${vars[@]}" -- "${c%:*}" "${1:-}" 2>/dev/null)"
    [[ "$got" == "${c##*:}" ]] || out+="${c%:*} "
  done
  echo "${out% }"
}

# --- 1. the spec's cases on the real cnf ------------------------------------------
for c in "${CASES[@]}"; do
  got="$(phase -- "${c%:*}" 2>&1)"
  [[ "$got" == "${c##*:}" ]] && pass "1. ${c%:*} -> $got" || fail "1. ${c%:*}: want ${c##*:}, got '$got'"
done
[[ "$(yq -r '.env.rhythm | [.timezone, .night_start, .night_end] | join(" ")' "$APP_ROOT/csi-spl-cnf/csi-spl/all.env.yaml")" == "Europe/Berlin 20 7" ]] &&
  pass "1. cnf env.rhythm is Europe/Berlin 20 to 7" || fail "1. cnf env.rhythm is not Europe/Berlin 20 to 7"

# --- 2. red control: a fixed +1 offset -------------------------------------------------
PLUS1='spl_rhythm_hour() { date -u -d "@$(( $(date -d "$1" +%s) + 3600 ))" +%H; }'
got="$(wrong_cases -- "$PLUS1")"
[[ "$got" == "2026-07-15T18:00Z 2026-07-15T05:00Z" ]] &&
  pass "2. RED control: a fixed +1 offset fails both July cases ($got)" || fail "2. fixed +1 offset: want both July cases wrong, got '$got'"

# --- 3. red control: TZ=CET on a box with no zoneinfo/CET -------------------------------
# a tz database with Europe/Berlin and no CET, as on box 1 (spec 166 0.2)
mkdir -p "$T/zones/Europe"
cp /usr/share/zoneinfo/Europe/Berlin "$T/zones/Europe/Berlin"
CET='spl_rhythm_hour() { TZ=CET date -d "$1" +%H; }'
got="$(TZDIR="$T/zones" TZ=CET date -d 2026-01-15T19:00Z +%H)"
[[ "$got" == 19 ]] && pass "3. with no zoneinfo/CET, TZ=CET reads 19:00Z as hour 19 (UTC)" || fail "3. TZ=CET read 19:00Z as '$got', not 19"
got="$(wrong_cases TZDIR="$T/zones" -- "$CET")"
[[ "$got" == "2026-01-15T19:00Z 2026-07-15T18:00Z 2026-07-15T05:00Z 2026-01-15T06:00Z" ]] &&
  pass "3. RED control: TZ=CET with no zoneinfo/CET fails 2026-01-15T19:00Z (wrong: $got)" || fail "3. TZ=CET: want every case but 18:59Z wrong, got '$got'"
got="$(wrong_cases TZDIR="$T/zones" --)"
[[ -z "$got" ]] && pass "3. the action itself, on the same tz database, gets every case right" || fail "3. action on the CET-less tz database: wrong '$got'"

# --- 4. the guard: a zone with no tz database file ---------------------------------------
printf 'env:\n  rhythm:\n    timezone: CET\n' >"$T/cet.yaml"
out="$(phase TZDIR="$T/zones" RHYTHM_CNF="$T/cet.yaml" -- 2026-01-15T19:00Z 2>&1)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"timezone 'CET' has no tz database file"* ]] &&
  pass "4. a cnf timezone CET with no zoneinfo/CET is refused (rc=$rc)" || fail "4. CET not refused: rc=$rc '$out'"
got="$(phase TZDIR="$T/zones" -- 2026-01-15T19:00Z 2>&1)"
[[ "$got" == night ]] && pass "4. Europe/Berlin with its file -> night" || fail "4. Europe/Berlin: got '$got'"

# --- 5. night_start outside 0..23 ----------------------------------------------------------
for bad in 24 -1 x; do
  printf 'env:\n  rhythm:\n    night_start: %s\n' "$bad" >"$T/bad.yaml"
  out="$(phase RHYTHM_CNF="$T/bad.yaml" -- 2026-01-15T19:00Z 2>&1)"; rc=$?
  [[ "$rc" -ne 0 && "$out" == *"night_start must be an hour 0..23"* ]] &&
    pass "5. cnf night_start $bad is refused" || fail "5. night_start $bad: rc=$rc '$out'"
done
VDIR="$APP_ROOT/csi-spl-cnf/src/python/conf-validator"
PY="${CONF_VALIDATOR_PYTHON:-python3}"
if "$PY" -c 'import pydantic, pydantic_yaml' >/dev/null 2>&1; then
  (cd "$VDIR" && "$PY" -m unittest tests.test_rhythm >"$T/py.out" 2>&1) &&
    pass "5. conf-validator tests/test_rhythm.py (night_start outside 0..23 refused)" || fail "5. test_rhythm.py: $(tail -5 "$T/py.out")"
else
  echo "SKIP: 5. conf-validator python not on hand (CONF_VALIDATOR_PYTHON); tests/test_rhythm.py runs in the cnf CI job"
fi

# --- 6. a bad RHYTHM_NOW; a window inside one day -------------------------------------------
out="$(phase -- not-a-date 2>&1)"; rc=$?
[[ "$rc" -ne 0 && "$out" == *"RHYTHM_NOW is not a date"* ]] && pass "6. RHYTHM_NOW=not-a-date is refused" || fail "6. bad RHYTHM_NOW: rc=$rc '$out'"
printf 'env:\n  rhythm:\n    night_start: 1\n    night_end: 5\n' >"$T/inday.yaml"
got="$(phase RHYTHM_CNF="$T/inday.yaml" -- 2026-01-15T00:00Z) $(phase RHYTHM_CNF="$T/inday.yaml" -- 2026-01-15T04:00Z)"
[[ "$got" == "night day" ]] && pass "6. window 1 to 5: 01:00 CET night, 05:00 CET day" || fail "6. window 1 to 5: got '$got'"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1

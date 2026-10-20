#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a part that times out reports ITS OWN budget, never the shared 300 s.
#          The TIMED OUT note printed _pp_timeout (300) for every part, so lanes
#          whose api (900 s full tier) or wui (420 s) budget ran out read
#          "TIMED OUT after 300s" and raised the wrong number (2026-10-07).
#   1. api part, full tier, PRE_PUSH_API_FULL_TIMEOUT=2 -> "TIMED OUT after 2s"
#   2. wui part, PRE_PUSH_WUI_TIMEOUT=3                 -> "TIMED OUT after 3s"
#   3. iac part, shared part budget 1                   -> "TIMED OUT after 1s"
#   4. api part, full tier, no env budget, load 32 on 16 cpus (stubbed reader)
#      -> "TIMED OUT after 1800s (api full default 900s x load 32/16 cpus,
#      cap 2700s)": the note names the load-scaled budget and the load it read
#      (`timeout` is stubbed to return 124 at once: no 30-min wait)
#   5. the env budget of case 1 is named in the note
#   6. a suite that passes at once logs no TIMED OUT note
#   7. a suite that fails at once (rc 1) logs no TIMED OUT note either
#   (red control for 6-7: a `do_log ... TIMED OUT after ...` emitted before
#   _pp_run's rc check passed cases 1-5, where every suite does time out)
#   Each part's suite in 1..3 is a stub that sleeps past its budget, so the real
#   `timeout` kills it; no real suite runs.
#------------------------------------------------------------------------------
set -uo pipefail
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_QUARANTINE_PATH GIT_COMMON_DIR GIT_PREFIX 2>/dev/null || true
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)
FUNC="$PROJ_ROOT/src/bash/run/check-pre-push.func.sh"

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

unset PRE_PUSH_PART_TIMEOUT PRE_PUSH_API_FULL_TIMEOUT PRE_PUSH_API_FULL_CAP PRE_PUSH_WUI_TIMEOUT
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
LOG="$T/log"
do_log() { echo "$*" >>"$LOG"; }
# shellcheck source=../run/check-pre-push.func.sh
. "$FUNC"

# A tree (not a git repo, so no baseline is built) whose suites all hang.
R="$T/tree"
mkdir -p "$R/csi-spl-api/src/bash/tests" "$R/csi-spl-iac/src/bash/tests" "$R/csi-spl-wui/node_modules/.pnpm" "$T/bin"
printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$R/csi-spl-api/src/bash/tests/run-all-tests.sh"
printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$R/csi-spl-iac/src/bash/tests/run-all-tests.sh"
echo lock >"$R/csi-spl-wui/pnpm-lock.yaml"; echo lock >"$R/csi-spl-wui/node_modules/.pnpm/lock.yaml"
printf '#!/usr/bin/env bash\nexec sleep 30\n' >"$T/bin/pnpm"; chmod +x "$T/bin/pnpm"
# Two trees whose iac suite returns at once: rc 0 and rc 1.
for rc in 0 1; do
  mkdir -p "$T/quick$rc/csi-spl-iac/src/bash/tests"
  printf '#!/usr/bin/env bash\necho "FAIL: quick"\nexit %s\n' "$rc" >"$T/quick$rc/csi-spl-iac/src/bash/tests/run-all-tests.sh"
done

note_of() {  # <part-fn> -> the "TIMED OUT after Ns" the run logged
  : >"$LOG"
  local -a _PP_NAMES=() _PP_STAT=() _PP_SECS=(); local _PP_FAILED=0 _PP_BASE_WT=""
  _pp_run "$1" "$1" "$R" nobase >/dev/null 2>&1
  grep -o 'TIMED OUT after [0-9]*s' "$LOG" | sed -n 1p
}
full_note_of() {  # <part-fn> -> the whole "TIMED OUT after Ns (<why>)" note
  : >"$LOG"
  local -a _PP_NAMES=() _PP_STAT=() _PP_SECS=(); local _PP_FAILED=0 _PP_BASE_WT=""
  _pp_run "$1" "$1" "$R" nobase >/dev/null 2>&1
  grep -o 'TIMED OUT after [0-9]*s[^)]*)' "$LOG" | sed -n 1p
}
check() {  # <label> <want> <got>
  [[ "$3" == "$2" ]] && pass "$1" || fail "$1" "want '$2', got '$3'"
}

check "1. api full tier reports its 2 s budget" "TIMED OUT after 2s" \
  "$(PRE_PUSH_API_FULL_TIMEOUT=2 _PP_TIER=full note_of _pp_part_api)"
check "2. wui reports its 3 s budget" "TIMED OUT after 3s" \
  "$(PATH="$T/bin:$PATH" PRE_PUSH_WUI_TIMEOUT=3 note_of _pp_part_wui)"
check "3. iac reports the shared part budget" "TIMED OUT after 1s" \
  "$(_pp_timeout=1; note_of _pp_part_iac)"

check "4. api full tier names its load-scaled budget and the load" \
  "TIMED OUT after 1800s (api full default 900s x load 32/16 cpus, cap 2700s)" \
  "$(_pp_load_read() { _PP_LOAD="32 16"; }; timeout() { return 124; }; _PP_TIER=full full_note_of _pp_part_api)"
check "5. an env budget is named in the note" "TIMED OUT after 2s (PRE_PUSH_API_FULL_TIMEOUT)" \
  "$(PRE_PUSH_API_FULL_TIMEOUT=2 _PP_TIER=full full_note_of _pp_part_api)"

check "6. a passing suite logs no TIMED OUT note" "" \
  "$(R="$T/quick0"; _pp_timeout=30; note_of _pp_part_iac)"
check "7. a suite failing with rc 1 logs no TIMED OUT note" "" \
  "$(R="$T/quick1"; _pp_timeout=30; note_of _pp_part_iac)"

echo "--- $((7 - fails))/7 passed ---"
[[ "$fails" -eq 0 ]]

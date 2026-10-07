#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a part that times out reports ITS OWN budget, never the shared 300 s.
#          The TIMED OUT note printed _pp_timeout (300) for every part, so lanes
#          whose api (900 s full tier) or wui (420 s) budget ran out read
#          "TIMED OUT after 300s" and raised the wrong number (2026-10-07).
#   1. api part, full tier, PRE_PUSH_API_FULL_TIMEOUT=2 -> "TIMED OUT after 2s"
#   2. wui part, PRE_PUSH_WUI_TIMEOUT=3                 -> "TIMED OUT after 3s"
#   3. iac part, shared part budget 1                   -> "TIMED OUT after 1s"
#   Each part's suite is a stub that sleeps past its budget, so the real
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

unset PRE_PUSH_PART_TIMEOUT PRE_PUSH_API_FULL_TIMEOUT PRE_PUSH_WUI_TIMEOUT
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

note_of() {  # <part-fn> -> the "TIMED OUT after Ns" the run logged
  : >"$LOG"
  local -a _PP_NAMES=() _PP_STAT=() _PP_SECS=(); local _PP_FAILED=0 _PP_BASE_WT=""
  _pp_run "$1" "$1" "$R" nobase >/dev/null 2>&1
  grep -o 'TIMED OUT after [0-9]*s' "$LOG" | sed -n 1p
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

echo "--- $((3 - fails))/3 passed ---"
[[ "$fails" -eq 0 ]]

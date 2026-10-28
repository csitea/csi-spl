#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: scripts/go-mod-download.sh, offline: go is a stub that logs each
#          call and fails its first FAKE_GO_FAILS calls.
#   1. success on the first try: exit 0, 1 call
#   2. fail once, then succeed: exit 0, 2 calls (the retry is real)
#   3. always fail: exit 1, exactly 3 calls and the FAIL line (a hard
#      failure is not swallowed)
#   4. extra arguments reach `go mod download` unchanged
#   5. wf 10 has no uncommented bare `go mod download` run line, and calls
#      the helper exactly 5 times
#   6. CONTROL: the stub records a call it is given
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
S="$PROJ_ROOT/src/bash/scripts/go-mod-download.sh"
WF="$APP_ROOT/.github/workflows/10_ci-quality.yml"

mkdir -p "$T/stub"
cat >"$T/stub/go" <<'STUB'
#!/usr/bin/env bash
echo "go $*" >>"$FAKE_LOG"
n=$(wc -l <"$FAKE_LOG")
((n > ${FAKE_GO_FAILS:-0}))
STUB
chmod +x "$T/stub/go"
run() { : >"$T/log"; env PATH="$T/stub:$PATH" FAKE_LOG="$T/log" GO_MOD_DOWNLOAD_SLEEP=0 "$@" bash "$S" "${ARGS[@]}" >"$T/out" 2>&1; }
calls() { wc -l <"$T/log" | tr -d ' '; }

# 1
ARGS=(); run FAKE_GO_FAILS=0; rc=$?
[[ $rc -eq 0 && $(calls) -eq 1 ]] && pass "1. success first try: exit 0, 1 call" || fail "1. first try: rc=$rc calls=$(calls)"

# 2
ARGS=(); run FAKE_GO_FAILS=1; rc=$?
[[ $rc -eq 0 && $(calls) -eq 2 ]] && grep -q '::warning::.*try 1 of 3' "$T/out" \
  && pass "2. fail once, then succeed: exit 0, 2 calls" || fail "2. retry: rc=$rc calls=$(calls) $(cat "$T/out")"

# 3
ARGS=(); run FAKE_GO_FAILS=99; rc=$?
[[ $rc -eq 1 && $(calls) -eq 3 ]] && grep -qx 'FAIL go mod download failed 3x' "$T/out" \
  && pass "3. always fail: exit 1, exactly 3 calls, the FAIL line" || fail "3. hard failure: rc=$rc calls=$(calls) $(cat "$T/out")"

# 4
ARGS=(-x golang.org/x/image); run FAKE_GO_FAILS=0; rc=$?
[[ $rc -eq 0 ]] && grep -qx 'go mod download -x golang.org/x/image' "$T/log" \
  && pass "4. arguments are passed through" || fail "4. args: rc=$rc $(cat "$T/log")"

# 5
bare=$(grep -vE '^\s*#' "$WF" | grep -cE 'run: *go mod download')
helper=$(grep -vE '^\s*#' "$WF" | grep -c 'run: bash ../../../../csi-spl-orc/src/bash/scripts/go-mod-download.sh')
[[ $bare -eq 0 && $helper -eq 5 ]] && pass "5. wf 10: no bare go mod download, 5 helper calls" \
  || fail "5. wf 10: bare=$bare helper=$helper (want 0 and 5)"

# 6
: >"$T/log"; env PATH="$T/stub:$PATH" FAKE_LOG="$T/log" go mod download x
grep -qx 'go mod download x' "$T/log" && pass "6. CONTROL: the stub records a call" || fail "6. CONTROL: stub log empty"

echo "=== $([[ $fails -eq 0 ]] && echo 'all go-mod-download.tst.sh assertions' || echo "$fails FAILED")"
[[ $fails -eq 0 ]]

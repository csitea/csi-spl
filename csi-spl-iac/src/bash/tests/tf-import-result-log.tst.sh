#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: do_tf_import logs OK when terraform import exits 0 and FATAL when it
#          does not (refactor round 1, practice 24: the rc test is [[ ]]).
#          A stub terraform on PATH exits with $STUB_TF_IMPORT_RC on `import`;
#          do_tf_init is stubbed (it only has to set tf_run_path).
#          CONTROL: the two cases give different lines, so the check is not
#          blind to the rc.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ACTION_FILE="$PROJ_ROOT/src/bash/run/tf-import.func.sh"
require_action "$ACTION_FILE"
stub terraform 'case " $* " in *" import "*) exit "${STUB_TF_IMPORT_RC:-0}" ;; esac; exit 0'

# run_import <rc> -> the do_log lines of one do_tf_import run
run_import() {
  env -i PATH="$T/bin:/usr/bin:/bin" STUB_TF_IMPORT_RC="$1" ACTION_FILE="$ACTION_FILE" RUN_DIR="$T/run" \
      APP_PATH="$T" ORG=csi APP=spl ENV=dev STEP=000-step TARGET='res.name[0]' ID='an-id' bash -c '
    set -u
    do_log() { echo "$*"; }
    do_require_var() { :; }
    do_tf_init() { tf_run_path="$RUN_DIR"; }
    source "$ACTION_FILE"
    do_tf_import
  ' 2>/dev/null
}

ok=$(run_import 0)
grep -qx 'OK Resource imported successfully: res.name\[0\] -> an-id' <<<"$ok" \
  && pass "import rc=0 -> OK line" || fail "import rc=0: $(tail -3 <<<"$ok")"
grep -q '^FATAL' <<<"$ok" && fail "import rc=0 also logged FATAL" || pass "import rc=0 -> no FATAL line"

bad=$(run_import 3)
grep -qx 'FATAL Failed to import resource: res.name\[0\] -> an-id' <<<"$bad" \
  && pass "import rc=3 -> FATAL line" || fail "import rc=3: $(tail -3 <<<"$bad")"
grep -q '^OK' <<<"$bad" && fail "import rc=3 also logged OK" || pass "import rc=3 -> no OK line"

[[ "$ok" != "$bad" ]] && pass "CONTROL: the rc changes the logged result" || fail "CONTROL: rc 0 and 3 logged the same"

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1

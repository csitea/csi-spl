#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: run-all-tests.sh --changed runs only the test files that name a
#          changed file or one of its functions, plus the always-run list
#          (doc fleet-hot-commands-2026-10-07.md 3.9), and --background
#          leaves a result file. In a temp git repo laid out like the real
#          one (csi-spl-orc/src/bash/tests + lib/bash/funcs), base = master:
#   1. a change in foo.func.sh runs foo.tst.sh + the always-run file and
#      NOT bar.tst.sh (CONTROL: bar.tst.sh prints a marker that must be
#      absent, and it is listed as skipped); 2/2
#   2. CONTROL: the default mode on the same tree still runs every file, 4/4
#   3. a renamed function still selects the test of its old name
#   4. an orc file no test names falls back to every file, 4/4
#   5. a doc change runs only the always-run file; a file outside the orc
#      tree no test names is ignored, not a fallback
#   6. a changed test runs itself; a failing selected test fails the run
#   7. no merge-base -> every file; 9. a ./run dispatcher change -> every file
#   8. --background returns at once; the result file appears when done and
#      carries rc + count; the log holds the run
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
PROJ_ROOT=$(cd "$TEST_DIR/../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
R="$T/repo"; O="$R/csi-spl-orc"; D="$O/src/bash/tests"
mkdir -p "$D" "$O/lib/bash/funcs" "$R/other"
cp "$PROJ_ROOT/src/bash/tests/run-all-tests.sh" "$PROJ_ROOT/src/bash/tests/changed-tests.sh" "$D/"
printf 'do_foo() { echo foo; }\n' >"$O/lib/bash/funcs/foo.func.sh"
printf 'do_bar() { echo bar; }\n' >"$O/lib/bash/funcs/bar.func.sh"
printf '#!/usr/bin/env bash\n# calls do_foo\necho ran-foo\n' >"$D/foo.tst.sh"
printf '#!/usr/bin/env bash\n# calls do_bar\necho ran-bar\n' >"$D/bar.tst.sh"
printf '#!/usr/bin/env bash\necho ran-always\n' >"$D/require-cloud-env.tst.sh"
printf '#!/usr/bin/env bash\necho ran-other\n' >"$D/other.tst.sh"
printf 'x\n' >"$O/run"; printf 'x\n' >"$O/README.md"; printf 'x\n' >"$R/other/data.txt"
g() { git -C "$R" -c user.name=t -c user.email=t@example.com "$@" >/dev/null 2>&1; }
g init -q -b master; g add -A; g commit -qm base; g checkout -qb lane
run() { (cd "$R" && ORC_TEST_BASE=master ORC_TEST_JOBS=2 bash "$D/run-all-tests.sh" "$@") >"$T/out" 2>&1; echo $?; }
has() { grep -qx -- "$1" "$T/out"; }
count() { grep -oE '[0-9]+/[0-9]+ test files passed' "$T/out"; }
reset_tree() { g checkout -q -- .; g clean -qfd; }

# 1
printf 'do_foo() { echo foo2; }\n' >"$O/lib/bash/funcs/foo.func.sh"
rc=$(run --changed)
[ "$rc" = 0 ] && has ran-foo && has ran-always && pass "1 foo.func.sh change runs foo.tst.sh + always-run" || fail "1 selection" "rc=$rc $(cat "$T/out")"
has ran-bar && fail "1 CONTROL bar.tst.sh must not run" "$(cat "$T/out")" || pass "1 CONTROL bar.tst.sh did not run"
grep -q 'skipped 2 of 4 files.*bar.tst.sh' "$T/out" && pass "1 the skipped files are printed with the reason" || fail "1 skip line" "$(cat "$T/out")"
[ "$(count)" = "2/2 test files passed" ] && pass "1 count 2/2" || fail "1 count" "$(count)"
# 2
rc=$(run)
[ "$rc" = 0 ] && has ran-bar && [ "$(count)" = "4/4 test files passed" ] && ! grep -q changed-only "$T/out" \
  && pass "2 CONTROL default mode runs every file (4/4)" || fail "2 default mode" "$(cat "$T/out")"
reset_tree
# 3
printf 'do_foo_renamed() { echo foo; }\n' >"$O/lib/bash/funcs/foo.func.sh"
rc=$(run --changed)
has ran-foo && ! has ran-bar && pass "3 a renamed function still selects its old test" || fail "3 rename" "$(cat "$T/out")"
reset_tree
# 4
printf 'do_zed() { :; }\n' >"$O/lib/bash/funcs/zed.func.sh"
rc=$(run --changed)
[ "$rc" = 0 ] && has ran-bar && [ "$(count)" = "4/4 test files passed" ] && grep -q 'running every file (no test names csi-spl-orc/lib/bash/funcs/zed.func.sh)' "$T/out" \
  && pass "4 an unmappable orc change falls back to every file" || fail "4 fallback" "$(cat "$T/out")"
reset_tree
# 5
printf 'y\n' >>"$O/README.md"; printf 'y\n' >>"$R/other/data.txt"
rc=$(run --changed)
[ "$rc" = 0 ] && has ran-always && ! has ran-foo && ! has ran-bar && [ "$(count)" = "1/1 test files passed" ] \
  && grep -q 'ignored csi-spl-orc/README.md (doc)' "$T/out" && grep -q 'ignored other/data.txt (outside csi-spl-orc' "$T/out" \
  && pass "5 doc + outside-orc changes run only the always-run file" || fail "5 doc/outside" "$(cat "$T/out")"
reset_tree
# 6
printf '#!/usr/bin/env bash\necho ran-other\nexit 1\n' >"$D/other.tst.sh"
rc=$(run --changed)
[ "$rc" != 0 ] && has ran-other && has 'FAILED: other.tst.sh' && ! has ran-bar \
  && pass "6 a changed test runs itself and its failure fails the run" || fail "6 changed test" "rc=$rc $(cat "$T/out")"
reset_tree
# 7
printf 'do_foo() { echo foo3; }\n' >"$O/lib/bash/funcs/foo.func.sh"
rc=$( (cd "$R" && ORC_TEST_BASE=no-such-ref bash "$D/run-all-tests.sh" --changed) >"$T/out" 2>&1; echo $?)
[ "$rc" = 0 ] && [ "$(count)" = "4/4 test files passed" ] && grep -q 'running every file (no merge-base' "$T/out" \
  && pass "7 no merge-base falls back to every file" || fail "7 no base" "$(cat "$T/out")"
reset_tree
# 9
printf 'y\n' >>"$O/run"
rc=$(run --changed)
[ "$(count)" = "4/4 test files passed" ] && grep -q 'running every file (csi-spl-orc/run is shared by every action)' "$T/out" \
  && pass "9 a ./run dispatcher change runs every file" || fail "9 dispatcher" "$(cat "$T/out")"
reset_tree
# 8
printf 'do_foo() { echo foo4; }\n' >"$O/lib/bash/funcs/foo.func.sh"
res="$T/bg/result"; mkdir -p "$T/bg"
start=$SECONDS
(cd "$R" && ORC_TEST_BASE=master bash "$D/run-all-tests.sh" --background "$res" --changed) >"$T/out" 2>&1
[ $((SECONDS - start)) -lt 3 ] && grep -q "result $res" "$T/out" && pass "8 --background returns at once" || fail "8 returns" "$(cat "$T/out")"
for _ in $(seq 1 100); do [ -f "$res" ] && break; sleep 0.2; done
[ "$(cat "$res" 2>/dev/null)" = "rc=0 2/2 test files passed" ] && grep -qx ran-foo "$res.log" \
  && pass "8 the result file carries rc + count, the log holds the run" || fail "8 result" "$(cat "$res" "$res.log" 2>&1)"

echo "-- run-all-tests-changed.tst.sh: $fails failed"
[ "$fails" -eq 0 ]

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
#  10. a function a TEST file defines is a stub: a test outside the orc
#      tree that stubs do_foo selects nothing (it is ignored, not foo.tst.sh);
#      CONTROL: a real source file outside the tree defining do_foo still
#      selects foo.tst.sh
#  11. a function the ./run dispatcher (src/bash/run/run.sh) defines is the
#      dispatcher's: a script that defines its own do_log stand-in does not
#      select every test that names do_log (SPL-5321: 389 orc files for one
#      relay change); CONTROL: a function only the script defines still
#      selects its test
#  12. a feature test file no test names (features/<f>/tests/...) is left
#      to the pre-push part orc-features, not a fallback to every file, and
#      run-eager-files.tst.sh joins the always-run list (SPL-5606, the D7 red
#      of 035dc1501 forced `full`, so no orc test ran before its push);
#      CONTROL: a feature file outside tests/ that no test names still falls
#      back to every file
#  13. a doc name tracked .md files share (spec.md) keys by its path, never
#      its basename: a change to b/spec.md selects neither specfix.tst.sh (it
#      writes a fixture spec.md) nor areader.tst.sh (it reads a/spec.md);
#      CONTROL: a change to a/spec.md selects areader.tst.sh; CONTROL: a
#      change to c/d/spec.md selects dreader.tst.sh, which names only its
#      trailing d/spec.md; CONTROL: a unique doc name (only-one.md) still
#      selects onefix.tst.sh by its name
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
# 10
plan() { (cd "$R" && ORC_TEST_BASE=master ORC_TEST_ALWAYS='' bash "$D/changed-tests.sh"); }
printf 'do_foo() { :; }\n' >"$R/other/stub.tst.sh"
[ "$(plan)" = "$(printf 'ignore\tother/stub.tst.sh\toutside csi-spl-orc, no orc test names it')" ] \
  && pass "10 a stub in a test file selects no test" || fail "10 stub" "$(plan)"
rm -f "$R/other/stub.tst.sh"; printf 'do_foo() { :; }\n' >"$R/other/real.func.sh"
[ "$(plan)" = "$(printf 'run\tfoo.tst.sh\tnames other/real.func.sh')" ] \
  && pass "10 CONTROL the same function in a real file selects foo.tst.sh" || fail "10 control" "$(plan)"
reset_tree
# 11
mkdir -p "$O/src/bash/run" "$O/src/bash/scripts"
printf 'do_log() { echo log; }\n' >"$O/src/bash/run/run.sh"
printf '#!/usr/bin/env bash\n# calls do_log\necho ran-log\n' >"$D/log.tst.sh"
printf '#!/usr/bin/env bash\n# calls do_relay_hop\n' >"$D/hop.tst.sh"
g add -A; g commit -qm 'dispatcher, a do_log test, a hop test'
printf 'do_log() { echo relay; }\ndo_relay_hop() { :; }\n' >"$O/src/bash/scripts/relay.sh"
g add -A; g commit -qm 'relay'
plan11=$( (cd "$R" && ORC_TEST_BASE=HEAD~1 ORC_TEST_ALWAYS='' bash "$D/changed-tests.sh") )
grep -q 'log.tst.sh' <<<"$plan11" && fail "11 a do_log stand-in must not select the do_log tests" "$plan11" \
  || pass "11 a stand-in for a dispatcher function selects no test that names it"
[ "$plan11" = "$(printf 'run\thop.tst.sh\tnames csi-spl-orc/src/bash/scripts/relay.sh')" ] \
  && pass "11 CONTROL a function only the script defines selects its test" || fail "11 control" "$plan11"
g reset -q --hard master; g clean -qfd
# 12
F="$O/src/bash/features/demo"; mkdir -p "$F/tests" "$F/lib"
printf '#!/usr/bin/env bash\necho eager\n' >"$D/run-eager-files.tst.sh"
printf '#!/usr/bin/env bash\necho t\n' >"$F/tests/test-demo-thing.sh"
printf 'demo_thing_fn() { :; }\n' >"$F/lib/demo-thing.inc.sh"
g add -A; g commit -qm 'a feature with a test, the eager test'
printf 'echo t2\n' >>"$F/tests/test-demo-thing.sh"; g add -A; g commit -qm 'feature test'
plan12=$( (cd "$R" && ORC_TEST_BASE=HEAD~1 bash "$D/changed-tests.sh") )
[ "$plan12" = "$(printf 'ignore\tcsi-spl-orc/src/bash/features/demo/tests/test-demo-thing.sh\tfeature test, run by the pre-push part orc-features\nrun\trequire-cloud-env.tst.sh\talways-run\nrun\trun-eager-files.tst.sh\talways-run')" ] \
  && pass "12 a feature test file is left to orc-features; run-eager-files.tst.sh is always-run" || fail "12 feature test" "$plan12"
printf 'demo_thing_fn2() { :; }\n' >>"$F/lib/demo-thing.inc.sh"; g add -A; g commit -qm 'feature lib'
plan12c=$( (cd "$R" && ORC_TEST_BASE=HEAD~1 bash "$D/changed-tests.sh") )
[ "$plan12c" = "$(printf 'full\tno test names csi-spl-orc/src/bash/features/demo/lib/demo-thing.inc.sh')" ] \
  && pass "12 CONTROL a feature file outside tests/ no test names still falls back to every file" || fail "12 control" "$plan12c"
g reset -q --hard master; g clean -qfd
# 13
mkdir -p "$R/a" "$R/b" "$R/c/d"; printf 'a\n' >"$R/a/spec.md"; printf 'b\n' >"$R/b/spec.md"; printf 'd\n' >"$R/c/d/spec.md"
printf 'o\n' >"$R/only-one.md"
printf '#!/usr/bin/env bash\nprintf x >"$T/spec.md"\n' >"$D/specfix.tst.sh"
printf '#!/usr/bin/env bash\ncat "$ROOT/a/spec.md"\n' >"$D/areader.tst.sh"
printf '#!/usr/bin/env bash\ncat "$FIX/d/spec.md"\n' >"$D/dreader.tst.sh"
printf '#!/usr/bin/env bash\nprintf x >"$T/only-one.md"\n' >"$D/onefix.tst.sh"
g add -A; g commit -qm 'two spec.md, a unique doc, their tests'
plan13() { printf 'z\n' >>"$R/$1"; g add -A; g commit -qm "$1"; (cd "$R" && ORC_TEST_BASE=HEAD~1 ORC_TEST_ALWAYS='' bash "$D/changed-tests.sh"); }
p13=$(plan13 b/spec.md)
[ "$p13" = "$(printf 'ignore\tb/spec.md\tdoc')" ] \
  && pass "13 a shared doc name keys by its path: b/spec.md selects no test" || fail "13 shared doc name" "$p13"
p13=$(plan13 a/spec.md)
[ "$p13" = "$(printf 'run\tareader.tst.sh\tnames a/spec.md')" ] \
  && pass "13 CONTROL a/spec.md selects areader.tst.sh, its path reader" || fail "13 control path" "$p13"
p13=$(plan13 c/d/spec.md)
[ "$p13" = "$(printf 'run\tdreader.tst.sh\tnames c/d/spec.md')" ] \
  && pass "13 CONTROL c/d/spec.md selects dreader.tst.sh by its trailing d/spec.md" || fail "13 control trailing path" "$p13"
p13=$(plan13 only-one.md)
[ "$p13" = "$(printf 'run\tonefix.tst.sh\tnames only-one.md')" ] \
  && pass "13 CONTROL a unique doc name selects onefix.tst.sh" || fail "13 control unique" "$p13"
g reset -q --hard master; g clean -qfd
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

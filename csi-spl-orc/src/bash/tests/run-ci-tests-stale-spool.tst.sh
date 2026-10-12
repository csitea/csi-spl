#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: run-ci-tests.sh rebuilds a tree build of spool that is OLDER than
#          its sources, once, before the pool. spool-env skips such a build
#          with a WARN on stderr, and the spawn-agents tests that read stderr
#          went red on that line: a false red pre-push (c-001 msg 60a51b4d).
#          A fresh build and an absent build (a CI clone) are not rebuilt; a
#          failed rebuild is printed and the tests still run.
#          A fake repo: the real runner and spool-env lib, a stub build.sh
#          that counts its calls, one feature test that fails when the build
#          is stale. RUN_CI_SUT=<file> runs another runner (the control).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
FEAT_DIR=$(cd "$TEST_DIR/../features" && pwd)
SUT="${RUN_CI_SUT:-$FEAT_DIR/run-ci-tests.sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; fails=$((fails + 1)); }
command -v tmux >/dev/null || { echo "FAIL: no tmux (run-ci-tests.sh needs it)"; exit 1; }

api=csi-spl-api/src/go/spool-hub-api
mk_repo() {  # <dir>: a git repo whose spool sources were committed now
  local r="$1"
  mkdir -p "$r/csi-spl-orc/src/bash/features/spawn-agents/lib" \
    "$r/csi-spl-orc/src/bash/features/fake/tests" "$r/csi-spl-orc/src/bash/tests" \
    "$r/csi-spl-api/src/bash" "$r/$api/cmd/spool" "$r/$api/bin"
  cp "$SUT" "$r/csi-spl-orc/src/bash/features/run-ci-tests.sh"
  cp "$FEAT_DIR/spawn-agents/lib/spool-env.inc.sh" "$r/csi-spl-orc/src/bash/features/spawn-agents/lib/"
  cat >"$r/csi-spl-api/src/bash/build.sh" <<'B'
#!/usr/bin/env bash
echo build >>"$BUILD_LOG"
[[ "${BUILD_FAIL:-}" == 1 ]] && exit 1
touch "$1"
B
  cat >"$r/csi-spl-orc/src/bash/features/fake/tests/test-stale.sh" <<'B'
#!/usr/bin/env bash
here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../../../../../.." && pwd)
. "$repo/csi-spl-orc/src/bash/features/spawn-agents/lib/spool-env.inc.sh" || { echo "FAIL: no spool-env lib"; exit 1; }
if _spool_bin_stale "$repo" "$repo/csi-spl-api/src/go/spool-hub-api/bin/spool"; then
  echo "FAIL: the build is stale"; exit 1
fi
echo "PASS: the build is fresh"
B
  echo 'package main' >"$r/$api/cmd/spool/main.go"
  git -C "$r" init -q
  git -C "$r" add -A
  git -C "$r" -c user.name=t -c user.email=t@example.com commit -qm src
}
run_ci() {  # <repo> [env...]: run the runner on the fake feature
  local r="$1"; shift
  : >"$T/build.log"
  env BUILD_LOG="$T/build.log" FEATURE_TEST_JOBS=1 "$@" \
    bash "$r/csi-spl-orc/src/bash/features/run-ci-tests.sh" fake >"$T/out" 2>&1
}
builds() { grep -c build "$T/build.log"; }
check() {  # <label> <command...>: PASS when the command succeeds
  local l="$1"; shift
  if "$@"; then pass "$l"; else fail "$l"; fi
}

# 1. stale build: rebuilt once, the feature test sees a fresh build
mk_repo "$T/r1"; : >"$T/r1/$api/bin/spool"; chmod +x "$T/r1/$api/bin/spool"
touch -d 2026-01-01 "$T/r1/$api/bin/spool"
run_ci "$T/r1"; rc=$?
check "1 stale build: runner exits 0 (rc=$rc)" test "$rc" = 0 || cat "$T/out"
check "1 stale build: rebuilt once ($(builds))" test "$(builds)" = 1
check "1 stale build: the rebuild is printed" grep -q 'older than its sources: rebuilding' "$T/out"

# 2. fresh build: not rebuilt
mk_repo "$T/r2"; : >"$T/r2/$api/bin/spool"; chmod +x "$T/r2/$api/bin/spool"
touch -d '+1 hour' "$T/r2/$api/bin/spool"
run_ci "$T/r2"; rc=$?
check "2 fresh build: runner exits 0 (rc=$rc)" test "$rc" = 0
check "2 fresh build: not rebuilt ($(builds))" test "$(builds)" = 0

# 3. no build (a CI clone): not built, nothing printed about it
mk_repo "$T/r3"
run_ci "$T/r3"; rc=$?
check "3 absent build: not built ($(builds))" test "$(builds)" = 0
check "3 absent build: nothing printed" test "$(grep -c 'spool build' "$T/out")" = 0

# 4. failed rebuild: printed, the tests still run (and see the stale build)
mk_repo "$T/r4"; : >"$T/r4/$api/bin/spool"; chmod +x "$T/r4/$api/bin/spool"
touch -d 2026-01-01 "$T/r4/$api/bin/spool"
run_ci "$T/r4" BUILD_FAIL=1; rc=$?
check "4 failed rebuild: printed" grep -q 'spool rebuild FAILED' "$T/out"
check "4 failed rebuild: the tests still ran" grep -q 'FAIL: the build is stale' "$T/out"
check "4 failed rebuild: runner exits 1 (rc=$rc)" test "$rc" = 1

echo "--- $fails failure(s)"
(( fails == 0 ))

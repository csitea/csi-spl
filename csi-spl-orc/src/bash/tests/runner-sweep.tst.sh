#!/usr/bin/env bash
# runner-sweep.tst.sh - idle runners only, and only the scratch the brief names.
#   0. box-disk-sweep accepts step runners (on origin/master the same command
#      exits 2: unknown step 'runners' — the red)
#   1. dry run plans the idle runner's old scratch and removes nothing
#   2. DRY_RUN=0 removes only that scratch; busy, young, repo, .runner,
#      .credentials* and a symlink target stay
#   3. a missing runner root skips

set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

RS="$PROJ_ROOT/src/bash/scripts/runner-sweep.sh"
SW="$PROJ_ROOT/src/bash/scripts/box-disk-sweep.sh"

out="$(DRY_RUN=1 BOX_SWEEP_STEPS=runners BOX_SWEEP_RUNNER_ROOT="$T/no-runners" BOX_SWEEP_LOCK="$T/r.lock" BOX_SWEEP_MOUNTS="$T" BOX_SWEEP_NOTE=0 bash "$SW" 2>&1)"
rc=$?
[ "$rc" = 0 ] && grep -q "SKIP runner root $T/no-runners not found" <<<"$out" \
  && pass "0. the sweep dry-runs step runners (red on origin/master: unknown step)" \
  || fail "0. sweep runners (rc $rc: $out)"

R="$T/runners" F="$T/fake"
mkdir -p "$R/idle/_work/_temp" "$R/idle/_diag" "$R/busy/_work/_temp" "$R/busy/_diag" "$R/idle/_work/repo" "$R/busy/_work/repo" "$F/bin"
printf 'x\n' >"$T/outside"
ln -s "$T/outside" "$R/idle/_work/_temp/link"
for d in idle busy; do
  printf 'x\n' >"$R/$d/_work/_temp/old1"
  printf 'x\n' >"$R/$d/_work/_temp/old2"
  printf 'x\n' >"$R/$d/_work/_temp/new"
  printf 'x\n' >"$R/$d/_work/_temp/.credentials"
  printf 'x\n' >"$R/$d/_diag/old.log"
  printf 'x\n' >"$R/$d/_diag/new.log"
  printf 'x\n' >"$R/$d/_diag/notes.txt"
  printf 'x\n' >"$R/$d/_work/repo/f"
  printf 'x\n' >"$R/$d/.credentials"
  printf 'x\n' >"$R/$d/.runner"
done
old() { find "$@" -exec touch -h -d '3 days ago' {} +; }
old "$R/idle/_work/_temp/old1" "$R/idle/_work/_temp/old2" "$R/idle/_work/_temp/.credentials" \
  "$R/idle/_diag/old.log" "$R/idle/_diag/notes.txt" \
  "$R/busy/_work/_temp/old1" "$R/busy/_work/_temp/old2" "$R/busy/_diag/old.log"
touch "$R/idle/_work/_temp/new" "$R/idle/_diag/new.log" "$R/busy/_work/_temp/new" "$R/busy/_diag/new.log"

# Busy iff the pgrep pattern names the busy runner. ere_escape keeps "/busy".
cat >"$F/bin/pgrep" <<'EOF'
#!/bin/bash
case "$*" in
  */busy) exit 0 ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$F/bin/pgrep"

out="$(PATH="$F/bin:$PATH" DRY_RUN=1 BOX_SWEEP_RUNNER_ROOT="$R" BOX_SWEEP_RUNNER_AGE=2 bash "$RS" 2>&1)"
rc=$?
[ "$rc" = 0 ] && grep -q "PLAN runner $R/idle: rm 3 file(s) (6B)" <<<"$out" \
  && grep -q "INFO runner $R/busy: busy, skipped" <<<"$out" \
  && [ -e "$R/idle/_work/_temp/old1" ] \
  && pass "1. dry run plans 3 old idle files and removes nothing" \
  || fail "1. dry run (rc $rc: $out)"

out="$(PATH="$F/bin:$PATH" DRY_RUN=0 BOX_SWEEP_RUNNER_ROOT="$R" BOX_SWEEP_RUNNER_AGE=2 bash "$RS" 2>&1)"
rc=$?
[ "$rc" = 0 ] && [ ! -e "$R/idle/_work/_temp/old1" ] && [ ! -e "$R/idle/_work/_temp/old2" ] && [ ! -e "$R/idle/_diag/old.log" ] \
  && [ -e "$R/idle/_work/_temp/new" ] && [ -e "$R/idle/_diag/new.log" ] \
  && [ -e "$R/idle/_work/_temp/.credentials" ] && [ -e "$R/idle/_diag/notes.txt" ] \
  && [ -e "$R/idle/_work/repo/f" ] && [ -e "$R/idle/.credentials" ] && [ -e "$R/idle/.runner" ] \
  && [ -e "$R/idle/_work/_temp/link" ] && [ -f "$T/outside" ] \
  && [ -e "$R/busy/_work/_temp/old1" ] && [ -e "$R/busy/_work/_temp/old2" ] && [ -e "$R/busy/_diag/old.log" ] \
  && pass "2. live run removes only old idle scratch and keeps the protected files" \
  || fail "2. live run (rc $rc: $out)"

out="$(PATH="$F/bin:$PATH" DRY_RUN=0 BOX_SWEEP_RUNNER_ROOT="$T/nonexistent" BOX_SWEEP_RUNNER_AGE=2 bash "$RS" 2>&1)"
rc=$?
[ "$rc" = 0 ] && grep -q "SKIP runner root $T/nonexistent not found" <<<"$out" \
  && pass "3. runner root not found" || fail "3. runner root not found (rc $rc: $out)"

echo "runner-sweep: ${fails} failure(s)"
[ "$fails" -eq 0 ]

#!/usr/bin/env bash
# Run every *.tst.sh next to this file; exit non-zero if any fails.
#
# Each test runs under a PER-TEST TIMEOUT (IAC_TEST_TIMEOUT, default 120 s): a
# test that hangs (tf-steps render is network-bound and once hung an agent for
# five hours) is KILLED and counted as a FAILURE with its name, never a hang.
# This is what makes the pre-push hook (which runs this suite) safe to gate on.
#
# IAC_TEST_TIER=fast (CLE-77824) is the pre-push hook's tier. It leaves out every
# test whose header carries the line '# pre-push-tier: slow' (terraform validate,
# the tpl-gen renders: minutes, and a toolchain a worktree does not have) and
# names each one. CI (workflow 10) never sets it and runs them all. In the fast
# tier a test that prints 'SKIP:' FAILS: a check the hook keeps must really run,
# so a missing tool is a loud failure, never a green that tested nothing.
set -uo pipefail
dir=$(cd "$(dirname "$0")" && pwd)
to="${IAC_TEST_TIMEOUT:-120}"
tier="${IAC_TEST_TIER:-full}"
case "$tier" in full|fast) ;; *) echo "IAC_TEST_TIER must be full or fast (got '$tier')" >&2; exit 2 ;; esac
fails=0 n=0 slow=0
out="$(mktemp)"; trap 'rm -f "$out"' EXIT
for t in "$dir"/*.tst.sh; do
  [[ -f "$t" ]] || continue
  if [[ "$tier" == fast ]] && head -40 "$t" | grep -qE '^# pre-push-tier: slow( |$)'; then
    echo "SKIP-TIER (fast tier; CI workflow 10 runs it): $(basename "$t")"; slow=$((slow + 1))
    continue
  fi
  n=$((n + 1))
  echo "=== $(basename "$t")"
  rc=0
  timeout -k 5 "$to" bash "$t" >"$out" 2>&1 || rc=$?
  cat "$out"
  if [[ "$rc" -eq 124 || "$rc" -eq 137 ]]; then
    echo "TIMED OUT (>${to}s), killed: $(basename "$t")"; fails=$((fails + 1))
  elif [[ "$rc" -ne 0 ]]; then
    echo "FAILED: $(basename "$t")"; fails=$((fails + 1))
  elif [[ "$tier" == fast ]] && grep -q '^SKIP:' "$out"; then
    echo "FAILED: $(basename "$t") SKIPPED a check in the fast tier ($(grep -m1 '^SKIP:' "$out")) -- install what it names, or mark the test '# pre-push-tier: slow' so CI owns it"
    fails=$((fails + 1))
  fi
done
echo "=== $((n - fails))/$n test files passed (tier=$tier, $slow left to CI)"
[[ "$fails" -eq 0 ]]

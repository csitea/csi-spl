#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: (SPL-5302) a hygiene red-control test that is KILLED mid-run leaves
#          no temp dir behind. Each of these tests copies the whole tracked
#          tree into its mktemp dir (~10k inodes a copy); on 2026-11-11 23 of
#          those dirs filled /tmp's inodes to 86% on a box.
#   The cause, measured (strace, bash 5.2): GNU timeout stops a part by sending
#   TERM to the child and then to its whole group, so the test's shell gets TERM
#   twice. When it lands while the shell reads a $(...) (out=$(sweep ...)), the
#   shell can die by the untrapped TERM before its EXIT trap runs rm -rf.
#   Per test below, KT_ROUNDS times: block its first sweep (a grep stub that
#   sleeps when run inside the test's temp dir), then TERM the `timeout` around
#   it, which relays the signal as on a timeout (child, then group), and assert:
#   1. the sweep was reached (else the kill proves nothing)
#   2. the test died by the signal (rc 124, or 143: timeout re-raises a TERM
#      it relayed); timeout KILLs it (rc 137) only after KT_GRACE s, so a
#      cleanup that is merely slow ends clean, one that ignores TERM does not
#   3. nothing is left under the test's TMPDIR
#   The leak is a race: without the fix 3/15, 8/24 and 7/24 kills leaked
#   (2026-11-11), so with 8 rounds x 3 tests this file stays red unless all 24
#   kills miss it, ~0.8^24 = 0.5%; one test alone can miss (8 clean kills seen).
#   The grace (SPL-5731): it was `timeout -k 5`, and on a loaded runner one
#   retired-relay cleanup outlasted the 5 s and ended rc=137 (wf 10 run
#   43823538144, 2026-11-16). Two controls hold the grace: a fixture whose
#   cleanup takes 8 s ends clean, one that ignores TERM ends rc=137.
#   The spin (SPL-5827): the 30 s grace did not hold either (wf 10 runs
#   44043493365 and 44146018540, rc=137): on CI's ubuntu 26.04 (bash 5.3) the
#   hygiene step's own shell, TERMed in its sweeps, can spin in its `wait`
#   ("wait: pid <n> is not a child of this shell" without end, on its stdout),
#   so a test that reads the step in a $(...) never runs its TERM trap (3 in
#   ~1030 kills in an ubuntu:26.04 container, 0 in 1292 on bash 5.2). A third control
#   stands in for it: a BASH_ENV wait() in the step that ignores TERM and
#   writes forever; hygiene-box-users-allow.tst.sh must still end clean.
#------------------------------------------------------------------------------
# test-timeout: 400
# pre-push-tier: slow  (24 tree exports; CI workflow 10 runs it)
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
tmp_dir

fails=0
rounds="${KT_ROUNDS:-8}"
grace="${KT_GRACE:-30}"

real_grep=$(type -P grep) || { echo "FAIL: no grep on PATH"; exit 1; }
stub grep "case \"\$PWD/\" in \"\$KT_TMP\"/*) : >\"\$KT_MARK\"; sleep 120 ;; esac; exec $real_grep \"\$@\""

# kill_once <test path> <dir>: run it, TERM it in its first sweep; prints the
# verdict (setup: / rc=<n> / leak: / clean)
kill_once() {
  local path="$1" tmp="$2/tmp" mark="$2/mark" log="$2/log" tp rc i left
  mkdir -p "$tmp"
  ( cd "$APP_ROOT" && PATH="$T/bin:$PATH" TMPDIR="$tmp" KT_TMP="$tmp" KT_MARK="$mark" BASH_ENV="${KT_BASH_ENV:-${BASH_ENV:-}}" \
      exec timeout -k "$grace" 300 bash "$path" >"$log" 2>&1 ) &
  tp=$!
  for ((i = 0; i < 1200; i++)); do [[ -e "$mark" ]] && break; sleep 0.1; done
  if [[ ! -e "$mark" ]]; then
    kill -TERM "$tp" 2>/dev/null; wait "$tp" 2>/dev/null
    echo "setup: its sweep never started within 120 s: $(tail -1 "$log")"; return
  fi
  kill -TERM "$tp"
  wait "$tp"; rc=$?
  if [[ $rc -eq 137 ]]; then echo "rc=137, KILLed: still running $grace s after the TERM"; return; fi
  if [[ $rc -ne 124 && $rc -ne 143 ]]; then echo "rc=$rc, not stopped by the TERM"; return; fi
  if [[ -n "$(find "$tmp" -mindepth 1 -maxdepth 1)" ]]; then
    left=$(find "$tmp" -mindepth 1 -maxdepth 2 -printf '%P ')
    echo "leak: $(find "$tmp" | wc -l) inodes, ${left:0:160}"
  else
    echo clean
  fi
  rm -rf "$2"
}

# The grace controls: a test-lib fixture that sweeps from its temp dir like the
# real tests; slow: its EXIT cleanup takes 8 s (past the old 5 s grace),
# deaf: it ignores TERM, so only the KILL after the grace stops it.
fixture() {
  printf '%s\n' "source '$TEST_DIR/test-lib.inc.sh'; tmp_dir" "$2" \
    'cd "$T" && out=$(grep -r x .)' 'echo "not reached: $out"' >"$T/$1.fx.sh"
}
fixture slow "trap 'trap \"\" TERM; sleep 8; rm -rf \"\$T\"' EXIT"
fixture deaf "trap '' TERM"
v=$(kill_once "$T/slow.fx.sh" "$T/slow.ctl")
if [[ "$v" == clean ]]; then pass "control: a TERM cleanup of 8 s ends clean within the $grace s grace"
else fail "control: a TERM cleanup of 8 s should end clean, got: $v"; fi
v=$(kill_once "$T/deaf.fx.sh" "$T/deaf.ctl")
if [[ "$v" == rc=137,* ]]; then pass "control: a test that ignores TERM is KILLed after $grace s and fails"
else fail "control: a test that ignores TERM should end rc=137, got: $v"; fi

# The spin control: only the extracted step (its $0 is .../sweep.sh) gets the
# wait() that ignores TERM; the KILL after the grace stops the old $(...) read.
printf '%s\n' '[[ "$0" == */sweep.sh ]] && wait() { trap "" TERM; while :; do echo spin; sleep 0.05; done; }' >"$T/spin.env"
v=$(KT_BASH_ENV="$T/spin.env" kill_once "$TEST_DIR/hygiene-box-users-allow.tst.sh" "$T/spin.ctl")
if [[ "$v" == clean ]]; then pass "control: hygiene-box-users-allow.tst.sh ends clean when its step spins in wait and ignores TERM"
else fail "control: hygiene-box-users-allow.tst.sh should end clean when its step spins in wait, got: $v"; fi

for name in hygiene-owner-email-allow.tst.sh hygiene-box-users-allow.tst.sh hygiene-retired-relay.tst.sh; do
  clean=0 bad=""
  for ((r = 1; r <= rounds; r++)); do
    v=$(kill_once "$TEST_DIR/$name" "$T/$name.$r")
    if [[ "$v" == clean ]]; then clean=$((clean + 1)); else bad+="    | round $r: $v"$'\n'; fi
  done
  if [[ $clean -eq $rounds ]]; then
    pass "$name: TERMed in its sweep $rounds times, it died by the signal and left nothing under its TMPDIR"
  else
    fail "$name: TERMed in its sweep $rounds times, $((rounds - clean)) did not end clean"
    printf '%s' "$bad"
  fi
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1

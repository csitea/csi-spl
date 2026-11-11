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
#      it relayed)
#   3. nothing is left under the test's TMPDIR
#   The leak is a race: without the fix 3/15, 8/24 and 7/24 kills leaked
#   (2026-11-11), so with 8 rounds x 3 tests this file stays red unless all 24
#   kills miss it, ~0.8^24 = 0.5%; one test alone can miss (8 clean kills seen).
#------------------------------------------------------------------------------
# test-timeout: 400
# pre-push-tier: slow  (24 tree exports; CI workflow 10 runs it)
set -uo pipefail

TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
tmp_dir

fails=0
rounds="${KT_ROUNDS:-8}"

real_grep=$(type -P grep) || { echo "FAIL: no grep on PATH"; exit 1; }
stub grep "case \"\$PWD/\" in \"\$KT_TMP\"/*) : >\"\$KT_MARK\"; sleep 120 ;; esac; exec $real_grep \"\$@\""

# kill_once <test> <dir>: run it, TERM it in its first sweep; prints the
# verdict (setup: / rc=<n> / leak: / clean)
kill_once() {
  local name="$1" tmp="$2/tmp" mark="$2/mark" log="$2/log" tp rc i left
  mkdir -p "$tmp"
  ( cd "$APP_ROOT" && PATH="$T/bin:$PATH" TMPDIR="$tmp" KT_TMP="$tmp" KT_MARK="$mark" \
      exec timeout -k 5 300 bash "$TEST_DIR/$name" >"$log" 2>&1 ) &
  tp=$!
  for ((i = 0; i < 1200; i++)); do [[ -e "$mark" ]] && break; sleep 0.1; done
  if [[ ! -e "$mark" ]]; then
    kill -TERM "$tp" 2>/dev/null; wait "$tp" 2>/dev/null
    echo "setup: its sweep never started within 120 s: $(tail -1 "$log")"; return
  fi
  kill -TERM "$tp"
  wait "$tp"; rc=$?
  if [[ $rc -ne 124 && $rc -ne 143 ]]; then echo "rc=$rc, not stopped by the TERM"; return; fi
  if [[ -n "$(find "$tmp" -mindepth 1 -maxdepth 1)" ]]; then
    left=$(find "$tmp" -mindepth 1 -maxdepth 2 -printf '%P ')
    echo "leak: $(find "$tmp" | wc -l) inodes, ${left:0:160}"
  else
    echo clean
  fi
  rm -rf "$2"
}

for name in hygiene-owner-email-allow.tst.sh hygiene-box-users-allow.tst.sh hygiene-retired-relay.tst.sh; do
  clean=0 bad=""
  for ((r = 1; r <= rounds; r++)); do
    v=$(kill_once "$name" "$T/$name.$r")
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

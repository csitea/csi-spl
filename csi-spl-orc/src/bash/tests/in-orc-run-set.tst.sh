#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: in_orc (test-lib.inc.sh) sources only the run files a test names
# in IN_ORC_RUN (perf round 15 row 01, SPL-5851). A dirname stub first on PATH
# logs each call, so the test counts the forks one in_orc pays at load:
#   (a) IN_ORC_RUN=spl-lane-issue: do_spl_lane_issue is defined, a function
#       of another run file (do_spl_spawn_queue) is not;
#   (b) unset, and (b2) empty: both are defined (today's loop, unchanged);
#   (c) fewer dirname calls with the set than without;
#   (d) a stem with no src/bash/run/<stem>.func.sh fails loudly, never skipped.
# Red control: on a test-lib.inc.sh whose in_orc ignores IN_ORC_RUN, (a), (c)
# and (d) fail (do_spl_spawn_queue is defined, the counts are equal, rc 0).
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

real_dirname=$(command -v dirname)
mkdir -p "$T/stub"
printf '#!/bin/sh\necho "dirname $*" >>"$STUB_LOG"\nexec %s "$@"\n' "$real_dirname" >"$T/stub/dirname"
chmod +x "$T/stub/dirname"

# probe [VAR=value]...: which of the two functions in_orc defined (in $T/o),
# its rc and the dirname calls it made (one stub log line each)
probe() {
  : >"$T/calls.log"
  SNIPPET='declare -F do_spl_lane_issue >/dev/null && echo has-lane-issue
declare -F do_spl_spawn_queue >/dev/null && echo has-spawn-queue; :' in_orc "$@" >"$T/o" 2>&1
  rc=$?
  n=$(grep -c '^dirname ' "$T/calls.log")
}

probe IN_ORC_RUN=spl-lane-issue; n_set=$n
grep -qx has-lane-issue "$T/o" && pass "(a) the set defines do_spl_lane_issue" || fail "(a) the set lacks do_spl_lane_issue: $(head -3 "$T/o")"
grep -qx has-spawn-queue "$T/o" && fail "(a) the set also sourced spl-spawn-queue.func.sh" || pass "(a) the set leaves do_spl_spawn_queue undefined"

probe; n_all=$n
grep -qx has-lane-issue "$T/o" && grep -qx has-spawn-queue "$T/o" && pass "(b) unset: every run file sourced" || fail "(b) unset: $(head -3 "$T/o")"

probe IN_ORC_RUN=
grep -qx has-lane-issue "$T/o" && grep -qx has-spawn-queue "$T/o" && pass "(b2) empty: every run file sourced" || fail "(b2) empty: $(head -3 "$T/o")"

echo "dirname calls: set=$n_set all=$n_all"
[ "$n_set" -gt 0 ] && [ "$n_set" -lt "$n_all" ] && pass "(c) fewer dirname calls with the set ($n_set < $n_all)" || fail "(c) dirname calls set=$n_set all=$n_all"

probe IN_ORC_RUN='spl-lane-issue no-such-run-stem'
[ "$rc" -ne 0 ] && grep -q 'no-such-run-stem' "$T/o" && pass "(d) a missing stem fails loudly (rc $rc)" || fail "(d) missing stem: rc $rc, $(head -3 "$T/o")"

[ "$fails" -eq 0 ] && echo "in-orc-run-set: OK" || echo "in-orc-run-set: $fails FAILED"
[ "$fails" -eq 0 ]

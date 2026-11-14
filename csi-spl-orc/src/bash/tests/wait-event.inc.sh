#!/usr/bin/env bash
#------------------------------------------------------------------------------
# The one bounded poll of the orc tests (SPL-5525, spec 016). A test waits on
# the event it then asserts (a file appears, a line in a log, a pid exits, a
# lock is held), never on a fixed "sleep N": a loaded runner outlasts any
# fixed nap, and an idle one wastes it. test-lib.inc.sh sources this file; a
# test that does not use test-lib sources it on its own:
#   source "$TEST_DIR/wait-event.inc.sh"
# Not a test itself: run-all-tests.sh runs *.tst.sh only.
#------------------------------------------------------------------------------

# wait_event <seconds> <cmd> [arg]... - run <cmd> every 0.1 s until it
# succeeds (rc 0), or <seconds> (whole) of tries have passed: rc 1 after one
# last try. The budget is a cap, not the wait: an event that happens returns
# at once. A test that waits inside its own "bash -c" passes the function in:
#   env WAIT_FN="$(declare -f wait_event)" bash -c 'eval "$WAIT_FN"; ...'
wait_event() {
  local n=$(( $1 * 10 )); shift
  while (( n-- > 0 )); do "$@" && return 0; sleep 0.1; done
  "$@"
}

# pid_gone <pid> - the process has exited (a zombie counts as gone: kill -0
# succeeds on one until its parent reaps it).
pid_gone() {
  ! kill -0 "$1" 2>/dev/null || [[ "$(awk '{ print $3 }' "/proc/$1/stat" 2>/dev/null)" == Z ]]
}

# env_idle <VAR=value> - no process carries that exact entry in the
# environment it started with: every process a sandboxed call left behind (a
# detached takeover, a loop's tick, a send) has ended. Use the sandbox's own
# unique value (SPOOL_ROOT=$T/...), never one the test shell itself exported.
# Waiting on it replaces "settle, then a short sleep for strays": a stray
# still running is waited for, not raced.
env_idle() { ! grep -qlzxF -- "$1" /proc/[0-9]*/environ 2>/dev/null; }

#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: SPL-6412 - no test leaves a gpg-agent running. A gpg-agent started
#   for a throwaway --homedir lives as long as that dir does (gpg 2.4 ends it
#   by inotify when the dir is removed), and each one holds an inotify
#   instance: on one fleet box 49 leaked agents used up the user's cap (126/128) and the
#   WUI unit part failed with EMFILE. Each case runs the gpg-using tests under
#   its own TMPDIR and counts the agents of this user whose --homedir is under
#   it, so another process's agents on the box never colour the verdict.
#     C1  the directive suite (its four selftests and its own keyring) and
#         channel-move-plan run to the end -> 0 agents left.
#     C2  selftest-core, test-directive and channel-move-plan each stopped
#         with SIGTERM while their agent runs -> 0 agents left (their EXIT
#         trap runs gpgconf --kill all and removes the dir).
#     C3  CONTROL: a planted agent whose homedir stays IS counted (1), so the
#         0s above are not a blind count; gpgconf --kill all ends it.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source=test-lib.inc.sh
source "$TEST_DIR/test-lib.inc.sh"
fails=0
ME="$(id -un)"
DIR_D="$PROJ_ROOT/src/bash/features/directive"
command -v gpg >/dev/null && command -v gpgconf >/dev/null || { echo "gpg-agent-leak: gpg/gpgconf not installed"; exit 1; }

# agents_under <dir> - how many gpg-agents of this user have a --homedir under <dir>
agents_under() { pgrep -u "$ME" -a gpg-agent | grep -cF -- "--homedir $1/"; }
none_under() { [[ "$(agents_under "$1")" == 0 ]]; }
# agent_up <dir> <ERE> - one runs for a homedir under <dir> matching <ERE>
agent_up() { pgrep -u "$ME" -a gpg-agent | grep -E -- "--homedir $1/$2 " >/dev/null; }

# --- C1: whole runs ------------------------------------------------------------------
mkdir -p "$T/c1"
TMPDIR="$T/c1" bash "$DIR_D/tests/test-directive.sh" >"$T/c1.log" 2>&1 || fail "C1: test-directive failed: $(grep -E 'FAIL' "$T/c1.log" | sed -n 1,3p)"
TMPDIR="$T/c1" bash "$TEST_DIR/channel-move-plan.tst.sh" >"$T/c1b.log" 2>&1 || fail "C1: channel-move-plan failed: $(tail -3 "$T/c1b.log")"
wait_event 20 none_under "$T/c1" && pass "C1: the directive suite and channel-move-plan leave 0 gpg-agents" ||
  fail "C1: $(agents_under "$T/c1") gpg-agent(s) left: $(pgrep -u "$ME" -a gpg-agent | grep -F -- "$T/c1/")"

# --- C2: stopped mid-run -------------------------------------------------------------
# stop_mid <case> <ERE of the homedir under $T/<case>> <cmd>... - start <cmd>
# under TMPDIR=$T/<case>, SIGTERM it once its agent runs, then count.
stop_mid() {
  local c="$1" rx="$2" pid; shift 2
  mkdir -p "$T/$c"
  GPG_LEAK_RUN="$T/$c" TMPDIR="$T/$c" "$@" >"$T/$c.log" 2>&1 &
  pid=$!
  if ! wait_event 120 agent_up "$T/$c" "$rx"; then
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    fail "C2 $c: its gpg-agent never started: $(tail -3 "$T/$c.log")"; return
  fi
  kill -TERM "$pid"; wait "$pid" 2>/dev/null
  # every process the run started has ended (a leaked agent too: it runs on
  # past the cap and is then counted)
  wait_event 60 env_idle "GPG_LEAK_RUN=$T/$c"
  wait_event 20 none_under "$T/$c" && pass "C2 $c: stopped with SIGTERM mid-run, 0 gpg-agents left" ||
    fail "C2 $c: stopped mid-run, $(agents_under "$T/$c") gpg-agent(s) left: $(pgrep -u "$ME" -a gpg-agent | grep -F -- "$T/$c/")"
}
stop_mid core 'dtest-[^/]+' bash "$DIR_D/scripts/selftest-core.sh"
stop_mid directive 'tmp\.[^/]+/gpg' bash "$DIR_D/tests/test-directive.sh"
stop_mid move 'tmp\.[^/]+/gpg' bash "$TEST_DIR/channel-move-plan.tst.sh"

# --- C3: CONTROL, a planted leak is counted -------------------------------------------
G="$T/c3/plant"; mkdir -p "$G"; chmod 700 "$G"
gpg-connect-agent --homedir "$G" /bye >/dev/null 2>&1
[[ "$(agents_under "$T/c3")" == 1 ]] && pass "C3 control: a planted agent whose homedir stays is counted (1)" ||
  fail "C3 control: the planted agent counted $(agents_under "$T/c3"), want 1"
gpgconf --homedir "$G" --kill all >/dev/null 2>&1
wait_event 20 none_under "$T/c3" && pass "C3 control: gpgconf --kill all ends it (0)" || fail "C3 control: still $(agents_under "$T/c3") after gpgconf --kill all"

echo "gpg-agent-leak: $fails failure(s)"
exit "$fails"

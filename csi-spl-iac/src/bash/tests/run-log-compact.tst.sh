#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: quiet logs for agents (token/focus practice 05). On a pipe (or
#          RUN_LOG=compact) do_log prints `LEVEL msg`: no ANSI, date, module,
#          box or pid; DEBUG only with RUN_LOG=debug; no framework START/STOP
#          banners and no "run completed" line. The log FILE keeps the full
#          line for every call.
#   Checks, for iac and orc run.sh (the real do_log + do_detect_log_mode,
#   extracted with awk): the compact lines, the drops, the file, the mode
#   switch. An action's own "START ::: <step>" line is kept. A do_log sourced
#   without ./run's main (RUN_LOG_COMPACT unset) keeps the full line.
#   Control: RUN_LOG_COMPACT=0 (what a terminal gets) prints the old
#   "[OK] <date> ..." line, so the compact checks are not blind.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
ESC=$'\033'

for mod in iac orc; do
  src="$REPO_ROOT/csi-spl-$mod/src/bash/run/run.sh"
  lib="$T/$mod.inc.sh"
  awk '/^do_log\(\) \{/,/^}/; /^do_detect_log_mode\(\) \{/,/^}/' "$src" >"$lib"
  grep -q '^do_detect_log_mode() {' "$lib" && grep -q 'print_ok' "$lib" \
    || { fail "$mod: extract do_log + do_detect_log_mode" "$src"; continue; }

  # emit <env...> -> stdout of a fixed set of do_log calls
  emit() {
    env -i PATH=/usr/bin:/bin LOG_DIR="$T/log-$mod" PROJ=p "$@" bash -c '
      source "$1"
      do_log "OK Resource imported successfully: a -> b"
      do_log "DEBUG a debug line"
      do_log "WARNING a warning"
      do_log "INFO START ::: running action :: do_x"
      do_log "INFO STOP  ::: running function :: do_x"
      do_log "INFO OK run.sh'"'"'s run completed"
      do_log "INFO START ::: provisioning step 010"
      do_log "FATAL it broke"
    ' _ "$lib"
  }

  out=$(emit RUN_LOG_COMPACT=1)
  want=$'OK Resource imported successfully: a -> b\nWARN a warning\nINFO START ::: provisioning step 010\nFATAL it broke'
  [[ "$out" == "$want" ]] && pass "$mod: pipe -> LEVEL msg, DEBUG + banners dropped" || fail "$mod: pipe output" "$(cat -v <<<"$out")"
  [[ "$out" != *"$ESC"* ]] && pass "$mod: no ANSI on a pipe" || fail "$mod: ANSI on a pipe"
  grep -qF 'Resource imported successfully:' <<<"$out" && pass "$mod: tf-import parsers still find their text" || fail "$mod: tf-import text"

  n=$(grep -c . "$T/log-$mod/p."*.log)
  [[ "$n" -eq 8 ]] && pass "$mod: the log file has all 8 lines" || fail "$mod: log file lines" "$n"
  grep -q '\[OK\] .*Resource imported successfully' "$T/log-$mod/p."*.log && grep -q "$ESC" "$T/log-$mod/p."*.log \
    && pass "$mod: the log file keeps the full format" || fail "$mod: log file format"

  out=$(emit RUN_LOG=debug RUN_LOG_COMPACT=1)
  grep -qx 'DEBUG a debug line' <<<"$out" && pass "$mod: RUN_LOG=debug keeps DEBUG" || fail "$mod: RUN_LOG=debug" "$out"

  out=$(emit RUN_LOG_COMPACT=0)
  grep -q '\[OK\] .*\[p\]\[@\] \[[0-9]*\] Resource imported successfully: a -> b' <<<"$out" \
    && pass "$mod: CONTROL terminal mode prints the full line" || fail "$mod: CONTROL full line" "$(cat -v <<<"$out")"
  [[ $(grep -c . <<<"$out") -eq 8 ]] && pass "$mod: CONTROL terminal mode drops nothing" || fail "$mod: CONTROL count"
  out=$(emit)
  grep -q '\[OK\] .*Resource imported successfully: a -> b' <<<"$out" && [[ $(grep -c . <<<"$out") -eq 8 ]] \
    && pass "$mod: sourced without main -> full line" || fail "$mod: sourced default" "$(cat -v <<<"$out")"

  mode() { env -i PATH=/usr/bin:/bin "$@" bash -c 'source "$1"; do_detect_log_mode; echo "$RUN_LOG_COMPACT"' _ "$lib"; }
  [[ "$(mode)" == 1 ]] && pass "$mod: mode: pipe -> compact" || fail "$mod: mode pipe"
  [[ "$(mode RUN_LOG=full)" == 0 ]] && pass "$mod: mode: RUN_LOG=full -> full" || fail "$mod: mode full"
  [[ "$(mode RUN_LOG=compact RUN_LOG_COMPACT=0)" == 1 ]] && pass "$mod: mode: RUN_LOG=compact wins" || fail "$mod: mode compact"
  [[ "$(mode RUN_LOG_COMPACT=0)" == 0 ]] && pass "$mod: mode: inherited value kept" || fail "$mod: mode inherited"
done

[[ "$fails" -eq 0 ]] && { echo "PASS: all $(basename "$0") assertions"; exit 0; }
echo "FAIL: $fails assertion(s) in $(basename "$0")"; exit 1

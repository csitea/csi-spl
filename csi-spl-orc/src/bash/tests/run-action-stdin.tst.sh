#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a ./run action gets the CALLER's stdin. The step loop used to read
# the action list from a here-string (`while read ... done <<< "$run_funcs"`),
# so every action's stdin was that here-string: a piped input never arrived,
# and an action run on a terminal saw no tty. The local hub's unlock,
# owner_add and owner_reset read secrets only from a tty and refused every
# real run through ./run (live proof on the box, 2026-10-13); their tests
# called the functions directly and stayed green.
#   1. a pipe into ./run reaches the action
#   2. ./run on a pty: the action's stdin is a tty
#   3. two actions in one ./run both run (the loop still walks the list)
# Each case runs against the orc AND the iac run.sh (kept in lockstep), in a
# throwaway tree with a probe action.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0
APP_ROOT=$(cd "$PROJ_ROOT/.." && pwd)

# probe_tree <module> -- a throwaway <ns>-orc tree running <module>'s run.sh
probe_tree() {
  local d="$T/$1/csi-x/csi-x-orc"
  mkdir -p "$d/src/bash/run" "$d/lib/bash"
  cp "$APP_ROOT/$1/src/bash/run/run.sh" "$d/src/bash/run/run.sh"
  cp -r "$PROJ_ROOT/lib/bash/funcs" "$d/lib/bash/funcs"
  ln -s src/bash/run/run.sh "$d/run"
  cat >"$d/src/bash/run/stdin-probe.func.sh" <<'EOF'
do_stdin_probe() { if [[ -t 0 ]]; then echo "PROBE tty"; else echo "PROBE in=$(cat)"; fi; }
EOF
  cat >"$d/src/bash/run/second-probe.func.sh" <<'EOF'
do_second_probe() { echo "PROBE second"; }
EOF
  echo "$d"
}

for m in csi-spl-orc csi-spl-iac; do
  d="$(probe_tree "$m")"

  out="$(cd "$d" && echo hello | RUN_LOG=compact ./run -a do_stdin_probe 2>&1)"
  grep -qx 'PROBE in=hello' <<<"$out" && pass "$m: a pipe into ./run reaches the action" ||
    fail "$m: piped stdin lost: $(grep PROBE <<<"$out" || tail -2 <<<"$out")"

  out="$(cd "$d" && RUN_LOG=compact script -qfec "./run -a do_stdin_probe" /dev/null </dev/null 2>&1 | tr -d '\r')"
  grep -qx 'PROBE tty' <<<"$out" && pass "$m: ./run on a pty gives the action a tty" ||
    fail "$m: no tty in the action: $(grep PROBE <<<"$out" || tail -2 <<<"$out")"

  out="$(cd "$d" && RUN_LOG=compact ./run -a do_stdin_probe -a do_second_probe </dev/null 2>&1)"
  [[ "$(grep -c '^PROBE' <<<"$out")" == 2 ]] && pass "$m: two actions in one ./run both run" ||
    fail "$m: two actions: $(grep PROBE <<<"$out" || tail -2 <<<"$out")"
done

echo "run-action-stdin: $fails failure(s)"
(( fails == 0 ))

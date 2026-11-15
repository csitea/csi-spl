#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: every `@param NAME` of an action is also a command-line flag
# (SPL-5548, spec 011): `./run -a <action> --image-ref v` exports
# IMAGE_REF=v. Before it, only the 6 actions with an `# @arg --flag VAR` line
# took a flag; any other --flag was silently ignored.
#   1. a flag maps to its variable (--name value, --name=value, bare = true)
#   2. a flag beats an env var of the same name set by the caller
#   3. an explicit @arg line still wins over the derived flag
#   4. an unknown flag fails (rc 11), names the action's flags, action not run
#   5. a param with no flag is still read from the env
#   6. a flag the action parses itself (`--kind)` arm, `@param --flag` line)
#      and the framework's --json pass through; a bare `--` ends the flags
# Each case runs against the orc, iac AND utl run.sh (kept byte-identical),
# in a throwaway tree with a probe action.
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
  cat >"$d/src/bash/run/flag-probe.func.sh" <<'PROBE'
#!/bin/bash
#------------------------------------------------------------------------------
# @description A probe action that prints the variables it was given.
# @param IMAGE_REF (optional) - an image reference
# @param PROBE_MODE (optional) - its flag is taken by the @arg below
# @param ENV_ONLY (optional) - set from the env only
# @param PROBE_BOOL (optional) - a boolean
# @param --from <x> (optional) - a flag the action reads from "$@" itself
# @arg --probe-mode PROBE_OTHER
# @example ./run -a do_flag_probe --image-ref reg/x:1
#------------------------------------------------------------------------------
do_flag_probe() {
  local kind=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --kind) kind="${2:-}"; shift 2 ;;
      *) shift ;;
    esac
  done
  echo "PROBE IMAGE_REF=${IMAGE_REF:-} PROBE_MODE=${PROBE_MODE:-} PROBE_OTHER=${PROBE_OTHER:-} ENV_ONLY=${ENV_ONLY:-} PROBE_BOOL=${PROBE_BOOL:-} kind=$kind"
}
PROBE
  echo "$d"
}

# probe <dir> [env...] -- <args...>: the PROBE line, else the last lines
probe() {
  local d=$1
  shift
  local envs=()
  while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  (cd "$d" && env -u IMAGE_REF -u PROBE_MODE -u PROBE_OTHER -u ENV_ONLY -u PROBE_BOOL \
    "${envs[@]}" RUN_LOG=compact ./run -a do_flag_probe "$@" </dev/null 2>&1)
  echo "RC=$?"
}

# check <name> <expected substring> <output>
check() {
  if grep -qF -- "$2" <<<"$3"; then pass "$1"; else fail "$1: want '$2', got: $(grep -E 'PROBE|FATAL|RC=' <<<"$3" | tr '\n' ' ')"; fi
}

for m in csi-spl-orc csi-spl-iac csi-spl-utl; do
  d="$(probe_tree "$m")"

  out="$(probe "$d" -- --image-ref reg/x:1)"
  check "$m: 1 --name value maps to NAME" "PROBE IMAGE_REF=reg/x:1 " "$out"
  out="$(probe "$d" -- --image-ref=reg/y:2 --probe-bool)"
  check "$m: 1 --name=value maps, a bare flag is true" "IMAGE_REF=reg/y:2 PROBE_MODE= PROBE_OTHER= ENV_ONLY= PROBE_BOOL=true" "$out"

  out="$(probe "$d" IMAGE_REF=from-env -- --image-ref from-flag)"
  check "$m: 2 a flag beats the env var" "PROBE IMAGE_REF=from-flag " "$out"

  out="$(probe "$d" -- --probe-mode v)"
  check "$m: 3 an explicit @arg wins over the derived flag" "PROBE_MODE= PROBE_OTHER=v " "$out"

  out="$(probe "$d" -- --imag-ref typo)"
  check "$m: 4 an unknown flag exits 11" "RC=11" "$out"
  check "$m: 4 the FATAL names the flag" "do_flag_probe: unknown flag --imag-ref" "$out"
  check "$m: 4 the FATAL lists the action's flags" "--image-ref" "$out"
  if grep -q '^PROBE' <<<"$out"; then fail "$m: 4 the action ran despite the unknown flag"; else pass "$m: 4 the action did not run"; fi

  out="$(probe "$d" ENV_ONLY=e1 IMAGE_REF=i1 --)"
  check "$m: 5 no flag: params read from the env" "IMAGE_REF=i1 PROBE_MODE= PROBE_OTHER= ENV_ONLY=e1 " "$out"
  out="$(probe "$d" ENV_ONLY=e2 -- --image-ref i2)"
  check "$m: 5 a param with no flag still read from the env" "IMAGE_REF=i2 PROBE_MODE= PROBE_OTHER= ENV_ONLY=e2 " "$out"

  out="$(probe "$d" -- --kind k1 --from a --json --image-ref i3 -- --nope)"
  check "$m: 6 own flags, --json and args after -- pass through" "IMAGE_REF=i3 PROBE_MODE= PROBE_OTHER= ENV_ONLY= PROBE_BOOL= kind=k1" "$out"
  check "$m: 6 own flags exit 0" "RC=0" "$out"
done

if cmp -s "$APP_ROOT/csi-spl-orc/src/bash/run/run.sh" "$APP_ROOT/csi-spl-iac/src/bash/run/run.sh" &&
  cmp -s "$APP_ROOT/csi-spl-orc/src/bash/run/run.sh" "$APP_ROOT/csi-spl-utl/src/bash/run/run.sh"; then
  pass "the three run.sh copies are byte-identical"
else
  fail "the orc, iac and utl run.sh copies differ"
fi

echo "run-param-flags: $fails failure(s)"
(( fails == 0 ))

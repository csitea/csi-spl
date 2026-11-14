#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: a module's paths come from the module whose ./run was called, even
# when its src/bash/run/run.sh is a symlink to another module's run.sh
# (SPL-5536, spec 011 refactor gap 2). do_set_vars took
# dirname(abs_path($0)), which followed run.sh's link through to the other
# module: PROJ_PATH, PROJ and PROJ_KIND became the other module's, and its
# actions were loaded. Now the resolve stops at the first file it reaches in
# a <dir>/src/bash/run/ dir, and only that dir is resolved.
#   1. today's layout (./run -> src/bash/run/run.sh, a real file): PROJ_PATH
#      is the module, its own action runs
#   2. module B's src/bash/run/run.sh linked to module A's (relative, then
#      absolute link): B/run sees PROJ_PATH=B, PROJ_KIND=orc and runs B's
#      action, not A's
#   3. a link to B/run from outside the tree (a bin dir) still lands in B
#   4. an ancestor dir reached through a link resolves to its real path, as
#      before
# Each case runs against the orc, iac and utl run.sh (kept in lockstep,
# csi-spl-iac run-sh-parity.tst.sh), in a throwaway tree.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# probe_mod <root> <kind> <tag> -- a <root>/csi-x/csi-x-<kind> module whose
# do_paths_probe prints <tag> and its paths; the caller adds its run.sh
probe_mod() {
  local d="$1/csi-x/csi-x-$2"
  mkdir -p "$d/src/bash/run" "$d/lib/bash"
  cp -r "$PROJ_ROOT/lib/bash/funcs" "$d/lib/bash/funcs"
  ln -s src/bash/run/run.sh "$d/run"
  cat >"$d/src/bash/run/paths-probe.func.sh" <<EOF
do_paths_probe() {
  echo "TAG=$3 PROJ_PATH=\$PROJ_PATH PROJ_KIND=\$PROJ_KIND APP=\$APP"
}
EOF
  echo "$d"
}

# probe <run> <out> -- run the probe action through <run>
probe() {
  HOME="$T/home" VAR_DIR="$T/var" "$1" -a do_paths_probe </dev/null >"$2" 2>&1
}

# want <label> <out> <tag> <proj-path> <kind>
want() {
  grep -q "TAG=$3 PROJ_PATH=$4 PROJ_KIND=$5 APP=csi-x" "$2" && pass "$1" ||
    fail "$1: want TAG=$3 PROJ_PATH=$4 PROJ_KIND=$5, got: $(grep -h 'TAG=\|FATAL' "$2" | sed -n 1p)"
}

mkdir -p "$T/home" "$T/var"
for m in csi-spl-orc csi-spl-iac csi-spl-utl; do
  r="$T/$m"
  a="$(probe_mod "$r" utl A)"
  cp "$APP_ROOT/$m/src/bash/run/run.sh" "$a/src/bash/run/run.sh"
  b="$(probe_mod "$r" orc B)"
  ra=$(cd "$a" && pwd -P) && rb=$(cd "$b" && pwd -P)

  probe "$a/run" "$T/out"
  want "$m: today's layout, A/run is A" "$T/out" A "$ra" utl

  ln -s ../../../../csi-x-utl/src/bash/run/run.sh "$b/src/bash/run/run.sh"
  (cd "$b" && probe ./run "$T/out")
  want "$m: B run.sh a relative link to A's, B/run is B" "$T/out" B "$rb" orc

  rm "$b/src/bash/run/run.sh" && ln -s "$a/src/bash/run/run.sh" "$b/src/bash/run/run.sh"
  probe "$b/run" "$T/out"
  want "$m: B run.sh an absolute link to A's, B/run is B" "$T/out" B "$rb" orc

  mkdir -p "$r/bin" && ln -s "$b/run" "$r/bin/xrun"
  probe "$r/bin/xrun" "$T/out"
  want "$m: a bin link to B/run is B" "$T/out" B "$rb" orc

  ln -s "$r/csi-x" "$r/csi-x-link"
  probe "$r/csi-x-link/csi-x-orc/run" "$T/out"
  want "$m: B reached through a linked ancestor is B's real path" "$T/out" B "$rb" orc
done

echo "run-paths-symlink: $fails failure(s)"
(( fails == 0 ))

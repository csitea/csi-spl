#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the ./run loader (iac and orc run.sh) derives names with parameter
#          expansion, never a $(basename)/$(dirname) fork per file - that fork
#          cost every ./run ~0.4 s (orc, 206 files) before it did anything
#          (perf round 4, C1).
#   Checks, for each run.sh: on a fixture tree BASE/org/app/app-iac the loader
#   maps kebab-case.func.sh -> do_snake_case (subdirs too), skips .pre/.post
#   hooks and a file whose function is missing, derives RUN_UNIT/ORG/APP/PROJ/
#   PROJ_KIND/VAR_DIR as before, and neither function body forks basename or
#   dirname.
#   Control: a fixture file with a space in its directory still maps.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

for mod in iac orc; do
  src="$REPO_ROOT/csi-spl-$mod/src/bash/run/run.sh"
  [ -f "$src" ] || { fail "$mod run.sh exists" "$src"; continue; }
  P="$T/$mod/base/org1/app1/app1-iac"
  mkdir -p "$P/src/bash/run/sub dir" "$P/lib/bash/funcs"
  sed '/^main "\$@"$/d' "$src" >"$P/src/bash/run/run.sh"
  ln -s src/bash/run/run.sh "$P/run"
  printf 'do_alpha_beta(){ :; }\n'  >"$P/src/bash/run/alpha-beta.func.sh"
  printf 'do_gamma(){ :; }\n'       >"$P/src/bash/run/sub dir/gamma.func.sh"
  printf 'do_lib_fn(){ :; }\n'      >"$P/lib/bash/funcs/lib-fn.func.sh"
  printf 'do_alpha_beta_pre(){ :; }\n' >"$P/src/bash/run/alpha-beta.pre.func.sh"
  printf 'do_other(){ :; }\n'       >"$P/src/bash/run/no-match.func.sh"

  out=$(cd "$T" && env -u ORG -u APP -u PROJ_KIND -u VAR_DIR bash -c '
    source "$0"; do_set_vars -a do_x >/dev/null 2>&1; do_load_functions >/dev/null 2>&1
    echo "RUN_UNIT=$RUN_UNIT ORG=$ORG APP=$APP PROJ=$PROJ PROJ_KIND=$PROJ_KIND VAR_DIR=$VAR_DIR FRW_PATH=$FRW_PATH"
    for k in "${!_func_to_file[@]}"; do echo "$k=${_func_to_file[$k]#$PROJ_PATH/}"; done | sort
    declare -f do_set_vars do_load_functions | grep -cE "\\\$\\((basename|dirname) " || true
  ' "$P/run")

  want_vars="RUN_UNIT=run.sh ORG=org1 APP=app1 PROJ=app1-iac PROJ_KIND=iac VAR_DIR=$T/$mod/var FRW_PATH="
  grep -qxF "$want_vars" <<<"$out" && pass "$mod: derived vars" || fail "$mod: derived vars" "$out"
  map=$(grep '^do_' <<<"$out")
  want_map=$'do_alpha_beta=src/bash/run/alpha-beta.func.sh\ndo_gamma=src/bash/run/sub dir/gamma.func.sh\ndo_lib_fn=lib/bash/funcs/lib-fn.func.sh'
  [ "$map" = "$want_map" ] && pass "$mod: function->file map (subdir, lib, hooks and misses skipped)" \
    || fail "$mod: function->file map" "$map"
  [ "$(tail -1 <<<"$out")" = 0 ] && pass "$mod: no basename/dirname fork in the loader" \
    || fail "$mod: no basename/dirname fork in the loader" "$(tail -1 <<<"$out") hits"
done

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"

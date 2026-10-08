#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: every orc action is resolvable by ./run. The loader (orc run,
# do_load_functions) registers ONE action per file, by its name:
# kebab-case.func.sh -> do_snake_case. A second do_* in the same file is
# sourced but `./run -a` answers "NOT found" (the weekly box-restart tick,
# 2026-10-08: do_spl_box_restart_tick lived in spl-box-restart-schedule.func.sh,
# and every 5-min cron tick failed; its test sourced the file directly).
#   1. do_spl_box_restart_run / _tick / _after resolve THROUGH ./run, each
#      with an env that stops it before it acts (a bad DRY_RUN, a bad slot,
#      an empty spool root): no "NOT found"
#   2. every do_* defined in src/bash/run/**/*.func.sh is its file's action,
#      or on the KNOWN list below (helpers the file's action calls, never
#      named by ./run); every "./run -a do_x" @example names a file's action
#   3. control: the checker flags a fixture file whose do_* is not its name
# lib/bash/funcs is out of scope: helper libraries, not actions.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
source "$TEST_DIR/test-lib.inc.sh"
fails=0

# do_* defined in a run file that is not the file's action, found
# 2026-10-09 (c-598). Provider dispatch helpers (cloud = gcp|none) and
# helpers; do_spl_peer_fence has a ./run @example that cannot resolve.
KNOWN="do_hub_deploy_verify_gcp do_hub_deploy_verify_none do_docs_publish_gcp
do_docs_publish_none do_lde_cli_wrapper do_spl_peer_fence do_secrets_check_gcp
do_secrets_check_none do_secrets_seed_gcp do_secrets_seed_none
do_hub_deploy_roll_none"

# loader_mismatch DIR - "<file> <do_fn>" per do_* that ./run cannot resolve:
# defined in a file of another name, or named by an @example with no file.
loader_mismatch() {
  local dir="$1" f b fn
  declare -A actions=()
  while IFS= read -r -d '' f; do
    b="${f##*/}"; b="${b%.func.sh}"
    [[ "$b" == *.pre || "$b" == *.post ]] && continue
    actions["do_${b//-/_}"]=1
  done < <(find "$dir" -type f -name '*.func.sh' -print0)
  while IFS= read -r -d '' f; do
    b="${f##*/}"; b="${b%.func.sh}"
    [[ "$b" == *.pre || "$b" == *.post ]] && continue
    while read -r fn; do
      [[ "$fn" == "do_${b//-/_}" ]] || echo "${f#"$dir"/} $fn"
    done < <(sed -nE 's/^[[:space:]]*(function[[:space:]]+)?(do_[A-Za-z0-9_]+)[[:space:]]*\(\).*/\2/p' "$f")
    while read -r fn; do
      [[ -n "${actions[$fn]:-}" ]] || echo "${f#"$dir"/} @example $fn"
    done < <(grep -oE '^# @example .*\./run -a do_[A-Za-z0-9_]+' "$f" | grep -oE 'do_[A-Za-z0-9_]+$')
  done < <(find "$dir" -type f -name '*.func.sh' -print0 | sort -z)
}

# ---- 1. the box-restart actions through ./run ---------------------------------
for a in "do_spl_box_restart_run DRY_RUN=x" "do_spl_box_restart_tick BOX_RESTART_AT=x" "do_spl_box_restart_after"; do
  read -ra w <<<"$a"
  out="$(cd "$PROJ_ROOT" && env VAR_DIR="$T/var" SPOOL_ROOT="$T/spool" "${w[@]:1}" ./run -a "${w[0]}" 2>&1)"
  if grep -q 'NOT found' <<<"$out"; then fail "./run -a ${w[0]} resolves: $(grep 'NOT found' <<<"$out")"
  elif grep -qE "BOX_RESTART_AT must be|DRY_RUN must be|no pending restart" <<<"$out"; then pass "./run -a ${w[0]} resolves and runs"
  else fail "./run -a ${w[0]} ran its guard: $out"; fi
done
[[ -z "$(find "$T/spool" -type f 2>/dev/null)" ]] && pass "the ./run calls wrote nothing in the spool root" ||
  fail "the ./run calls wrote: $(find "$T/spool" -type f)"

# ---- 2. every run file's do_* is its action -----------------------------------
new="$(loader_mismatch "$PROJ_ROOT/src/bash/run" | while read -r f fn rest; do
  [[ "$fn" == @example ]] && fn="$rest"
  grep -qw -- "$fn" <<<"$KNOWN" || echo "$f $fn"
done)"
[[ -z "$new" ]] && pass "every do_* in src/bash/run is its file's action (or KNOWN)" ||
  fail "./run cannot resolve (one action per file, kebab-case.func.sh -> do_snake_case):"$'\n'"$new"
for fn in do_spl_box_restart_run do_spl_box_restart_tick do_spl_box_restart_after; do
  grep -qw -- "$fn" <<<"$KNOWN" && fail "$fn is on the KNOWN list" || pass "$fn is not on the KNOWN list"
done

# ---- 3. control: the checker sees a mismatch ----------------------------------
mkdir -p "$T/fix/sub"
printf 'do_alpha_beta() { :; }\ndo_alpha_gamma() { :; }\n' >"$T/fix/alpha-beta.func.sh"
printf '# @example ./run -a do_nowhere\ndo_delta() { :; }\n' >"$T/fix/sub/delta.func.sh"
printf 'do_delta_pre() { :; }\n' >"$T/fix/sub/delta.pre.func.sh"
got="$(loader_mismatch "$T/fix")"
want=$'alpha-beta.func.sh do_alpha_gamma\nsub/delta.func.sh @example do_nowhere'
[[ "$got" == "$want" ]] && pass "control: a second do_* and an unresolvable @example are flagged, a .pre hook is not" ||
  fail "control: checker gave: $got"

echo "run-loader-convention: $fails failure(s)"
(( fails == 0 ))

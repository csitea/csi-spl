#!/usr/bin/env bash
#------------------------------------------------------------------------------
# Purpose: the ./run loader (run.sh of csi-spl-iac, -orc and -utl) sources
#          only the files an action needs (spec 027 os-tweaks-analysis.md row
#          1, SPL-5421). A file with only function definitions at top level
#          gets a stub per function that sources it on the first call; a file
#          with top-level code is sourced at start. Sourcing all 698 orc files
#          made a 69 MB Bash whose every fork cost 5.1..5.6 ms kernel time.
#   Checks, for each run.sh, on a fixture tree BASE/org/app/app-iac:
#     1. ./run -a do_alpha sources exactly: the framework lib, the action's
#        file, its PRE hook file and the file of the helper it calls (4 of
#        37); the eager file's top-level variable is set, its file sourced
#     2. a file whose only top-level code is `declare -F f || source ...`
#        stays lazy; its action runs
#     3. a heredoc with `}` and `x() {` lines inside a function: no false
#        function, the file stays lazy, the action prints the heredoc
#     4. a stub whose file does not define it fails with 127, no recursion
#   On the real trees (iac, orc, utl): every file the index calls lazy,
#   sourced alone, defines exactly the functions the index lists, sets no
#   variable and prints nothing; and each lazy file has a stub per function.
#   Controls: a run.sh whose index calls every file eager fails check 1; an
#   index that drops the do_* names fails the real-tree check.
#------------------------------------------------------------------------------
set -uo pipefail
TEST_DIR=$(cd "$(dirname "$0")" && pwd)
REPO_ROOT=$(cd "$TEST_DIR/../../../.." && pwd)

fails=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1 -- ${2:-}"; fails=$((fails + 1)); }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# fixture <dir> <run.sh source>: a project tree with lazy, eager, hook,
# guard and heredoc files plus 30 fillers
fixture() {
  local P="$1/base/org1/app1/app1-iac" R i
  R="$P/src/bash/run"
  mkdir -p "$R" "$P/lib/bash/funcs"
  cp "$2" "$R/run.sh" && chmod +x "$R/run.sh"
  ln -s src/bash/run/run.sh "$P/run"
  printf '%s\n' 'do_detect_base_paths(){ :; }' 'do_load_config(){ :; }' \
    'do_require_bin(){ :; }' 'do_verify_symlinks(){ :; }' 'do_parse_metadata(){ :; }' \
    >"$P/lib/bash/funcs/fw.func.sh"
  cat >"$R/alpha.func.sh" <<'EOA'
# the action: calls a helper of another lazy file, reads an eager constant
do_alpha() {
  helper_b
  echo "CONST=${CONST_E:-unset}"
  local k
  for k in "${!_rl_done[@]}"; do echo "LOADED ${_rl_files[k]##*/}"; done | sort
}
EOA
  printf 'do_alpha_pre() { echo PRE; }\n' >"$R/alpha.pre.func.sh"
  printf 'helper_b() {\n  echo HELPER_B\n}\ndo_beta() { helper_b; }\n' >"$R/beta.func.sh"
  printf 'CONST_E=fromE\ndo_eager_e() { :; }\n' >"$R/eager-e.func.sh"
  cat >"$R/guard-g.func.sh" <<'EOG'
declare -F helper_b >/dev/null ||
  source "$(dirname "${BASH_SOURCE[0]}")/beta.func.sh"
do_guard_g() { helper_b; }
EOG
  cat >"$R/here-doc.func.sh" <<'EOH'
do_here_doc() {
  cat <<'EOT'
}
fake_fn() {
EOT
}
EOH
  for i in $(seq -w 1 30); do printf 'do_fill_%s() { :; }\n' "$i" >"$R/fill-$i.func.sh"; done
  echo "$P"
}

run_in() { (cd "$1" && shift && env HOME="$T/home" RUN_LOG=compact "$@" 2>&1); }

check_fixture() {
  local mod="$1" P="$2" out want
  out=$(run_in "$P" ./run -a do_alpha)
  want=$'LOADED alpha.func.sh\nLOADED alpha.pre.func.sh\nLOADED beta.func.sh\nLOADED fw.func.sh'
  [[ "$(grep '^LOADED' <<<"$out")" == "$want" ]] && pass "$mod: 1. ./run -a do_alpha sources 4 of 37 lazy files" \
    || fail "$mod: 1. ./run -a do_alpha sources 4 of 37 lazy files" "$out"
  grep -qx PRE <<<"$out" && grep -qx HELPER_B <<<"$out" && grep -qx CONST=fromE <<<"$out" \
    && pass "$mod: 1. PRE hook, cross-file helper and eager constant work" \
    || fail "$mod: 1. PRE hook, cross-file helper and eager constant" "$out"
  out=$(run_in "$P" ./run -a do_guard_g)
  grep -qx HELPER_B <<<"$out" && pass "$mod: 2. a guarded file's action runs" || fail "$mod: 2. guarded action" "$out"
  out=$(run_in "$P" ./run -a do_here_doc)
  [[ "$(grep -xE '\}|fake_fn\(\) \{' <<<"$out")" == $'}\nfake_fn() {' ]] && pass "$mod: 3. heredoc action prints its text" \
    || fail "$mod: 3. heredoc action" "$out"
  out=$(cd "$T" && bash -c '
    source "$1"; trap - ERR; set +u; PROJ_PATH="$2"; do_load_functions >/dev/null 2>&1
    declare -F fake_fn >/dev/null && echo FAKE
    for f in "${_rl_files[@]}"; do echo "LAZY ${f##*/}"; done | sort
    zz_missing() { _rl_load 0 zz_missing "$@"; }; _rl_files[0]=/dev/null
    zz_missing 2>&1; echo "rc=$?"' _ "$T/$mod-nomain.sh" "$P")
  ! grep -q FAKE <<<"$out" && grep -qx 'LAZY guard-g.func.sh' <<<"$out" && grep -qx 'LAZY here-doc.func.sh' <<<"$out" \
    && ! grep -qx 'LAZY eager-e.func.sh' <<<"$out" \
    && pass "$mod: 2./3. guard and heredoc files lazy, eager file not, no false function" \
    || fail "$mod: 2./3. lazy/eager split" "$out"
  grep -q 'run.sh: /dev/null defines no zz_missing' <<<"$out" && grep -qx 'rc=127' <<<"$out" \
    && pass "$mod: 4. a stub its file does not define fails 127" || fail "$mod: 4. missing stub" "$out"
}

# real_tree <mod>: the index agrees with sourcing. As in ./run: the eager
# files are sourced and every function of a lazy file exists (here a marked
# dummy) before the lazy files are sourced, so a `declare -F f || source`
# guard does not fire. Then: no dummy is left (each lazy file defines every
# function the index gives it), no other function or variable appeared, and
# nothing was printed. One pass, not one per file: ~700 files in seconds.
real_tree() {
  local mod="$1" P="$REPO_ROOT/csi-spl-$1" nomain="${2:-$T/$1-nomain.sh}" out n
  out=$(cd "$P" && bash -c '
    source "$1"; trap - ERR; set +u; PROJ_PATH="$2"; q="$4"
    idx=$(find lib/bash/funcs src/bash/run -type f -name "*.func.sh" -print0 2>/dev/null | sort -z | xargs -0 -r awk "$_RUN_INDEX_AWK")
    lazy=(); eager=(); dummies=""; nl=$'"'"'\n'"'"'
    while IFS= read -r l; do
      if [[ "$l" =~ ^_rl_files\[[0-9]+\]=$q(.*)$q$ ]]; then lazy+=("${BASH_REMATCH[1]}")
      elif [[ "$l" =~ ^_rl_eager\+=\($q(.*)$q\)$ ]]; then eager+=("${BASH_REMATCH[1]}")
      elif [[ "$l" =~ ^([^ ]+)\(\)\ \{\ _rl_load\ [0-9]+\ ([^ ]+)\  ]]; then
        [[ "${BASH_REMATCH[1]}" == "${BASH_REMATCH[2]}" ]] || echo "BADSTUB $l"
        dummies+="${BASH_REMATCH[1]}() { : RL_DUMMY; }$nl"
      fi
    done <<<"$idx"
    echo "LAZYFILES ${#lazy[@]}"
    unset idx l
    for f in "${eager[@]}"; do source "$f" >/dev/null 2>&1 </dev/null; done
    eval "$dummies"; unset dummies
    f=""; a=(); b=(); c=(); d=()
    declare -F >"$3/f0"; compgen -v >"$3/v0"
    for f in "${lazy[@]}"; do source "$f" >>"$3/o" 2>&1 </dev/null; done
    declare -F >"$3/f1"; compgen -v >"$3/v1"; declare -f >"$3/bodies"
    mapfile -t a <"$3/f0"; mapfile -t b <"$3/f1"; mapfile -t c <"$3/v0"; mapfile -t d <"$3/v1"
    [[ ${#a[@]} -eq ${#b[@]} ]] || echo "NEWFUNC $(comm -13 <(sort "$3/f0") <(sort "$3/f1") | tr "\n" " ")"
    [[ ${#c[@]} -eq ${#d[@]} ]] || echo "SETSVAR $(comm -13 <(sort "$3/v0") <(sort "$3/v1") | tr "\n" " ")"
    grep -q "RL_DUMMY" "$3/bodies" && echo "NOTDEFINED $(grep -B2 "RL_DUMMY" "$3/bodies" | grep -oE "^[^ ]+ \(\)" | tr "\n" " ")"
    [[ -s "$3/o" ]] && echo "PRINTS $(head -c 300 "$3/o")"
    echo DONE' _ "$nomain" "$P" "$T" "'")
  n=$(sed -n 's/^LAZYFILES //p' <<<"$out")
  if grep -qx DONE <<<"$out" && ! grep -qE '^(NEWFUNC|SETSVAR|NOTDEFINED|PRINTS|BADSTUB) ' <<<"$out" && [[ "${n:-0}" -gt 0 ]]; then
    pass "$mod: real tree, $n lazy files define exactly their indexed functions, set and print nothing"
  else
    fail "$mod: real tree index vs sourcing" "$(grep -vE '^LAZYFILES' <<<"$out" | cut -c1-600 | sed -n '1,20p')"
  fi
}

for mod in iac orc utl; do
  src="$REPO_ROOT/csi-spl-$mod/src/bash/run/run.sh"
  [ -f "$src" ] || { fail "$mod run.sh exists" "$src"; continue; }
  sed '/^main "\$@"$/d' "$src" >"$T/$mod-nomain.sh"
  check_fixture "$mod" "$(fixture "$T/$mod" "$src")"
  real_tree "$mod"
done

# Control: an index that calls every file eager sources all 37 files
sed 's/^  if (eager) print "_rl_eager+=(" q ")"$/  if (1) print "_rl_eager+=(" q ")"/' \
  "$REPO_ROOT/csi-spl-iac/src/bash/run/run.sh" >"$T/run-eager.sh"
if cmp -s "$T/run-eager.sh" "$REPO_ROOT/csi-spl-iac/src/bash/run/run.sh"; then
  fail "CONTROL the eager plant applied" "sed matched nothing"
else
  P=$(fixture "$T/control" "$T/run-eager.sh")
  out=$(run_in "$P" ./run -a do_alpha)
  if ! grep -qx HELPER_B <<<"$out"; then fail "CONTROL the action ran" "$out"
  elif [[ "$(grep -c '^LOADED' <<<"$out")" -eq 4 ]]; then fail "CONTROL an all-eager index fails check 1" "$out"
  else pass "CONTROL an all-eager index fails check 1 (the action ran, no file lazy)"; fi
fi

# Control: an index that drops every do_* name is caught on the real tree
sed 's/^      fn\[++nf\] = name$/      if (name !~ \/^do_\/) fn[++nf] = name/' "$T/utl-nomain.sh" >"$T/utl-drop.sh"
if cmp -s "$T/utl-drop.sh" "$T/utl-nomain.sh"; then fail "CONTROL the index plant applied" "sed matched nothing"
else
  before=$fails
  real_tree utl "$T/utl-drop.sh" >/dev/null
  if (( fails > before )); then fails=$before; pass "CONTROL an index missing do_* names fails the real-tree check"
  else fail "CONTROL an index missing do_* names fails the real-tree check" "it passed"; fi
fi

[ "$fails" -eq 0 ] || { echo "$fails check(s) failed"; exit 1; }
echo "all checks passed"
